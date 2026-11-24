-- =============================================================================
-- Limitation des SMS OTP par numéro (hook Auth « Send SMS »).
-- Complète les limites natives de Supabase Auth :
--   * auth.sms.max_frequency (30 s entre deux codes pour un même numéro),
--   * auth.rate_limit.sms_sent (plafond global horaire du projet),
--   * auth.rate_limit.sign_in_sign_ups / token_verifications (par IP).
-- Ici : au plus 5 SMS par heure et 10 par jour pour un même numéro.
-- Le journal ne garde qu'une empreinte du numéro (pas le numéro en clair).
-- =============================================================================

create table private.otp_sms_log (
  id bigint generated always as identity primary key,
  phone_hash bytea not null,
  created_at timestamptz not null default now()
);
create index otp_sms_log_phone_idx on private.otp_sms_log (phone_hash, created_at desc);
grant all on private.otp_sms_log to service_role;

create or replace function public.svc_otp_sms_allowed(p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  h bytea := extensions.digest('otp:' || p_phone, 'sha256');
  last_hour int;
  last_day int;
begin
  perform pg_advisory_xact_lock(hashtextextended('otp:' || p_phone, 0));
  select count(*) filter (where created_at > now() - interval '1 hour'),
         count(*)
    into last_hour, last_day
  from private.otp_sms_log
  where phone_hash = h and created_at > now() - interval '24 hours';

  if last_hour >= 5 or last_day >= 10 then
    return jsonb_build_object('allowed', false, 'reason', case when last_hour >= 5 then 'hourly' else 'daily' end);
  end if;
  insert into private.otp_sms_log (phone_hash) values (h);
  return jsonb_build_object('allowed', true);
end;
$$;
revoke execute on function public.svc_otp_sms_allowed(text) from public, anon, authenticated;
grant execute on function public.svc_otp_sms_allowed(text) to service_role;

-- Purge du journal (48 h) ajoutée à la tâche de rétention.
create or replace function private.purge_otp_log()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from private.otp_sms_log where created_at < now() - interval '48 hours';
$$;
revoke execute on function private.purge_otp_log() from public, anon, authenticated;
select cron.schedule('jammtech-otp-log', '23 * * * *', $$select private.purge_otp_log()$$);
