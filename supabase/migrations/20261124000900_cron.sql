-- =============================================================================
-- Tâches planifiées (pg_cron)
-- =============================================================================
-- Les appels aux Edge Functions nécessitent deux secrets Vault, créés une fois
-- par environnement (voir README, « Mise en service ») :
--   select vault.create_secret('https://<ref>.supabase.co', 'project_url');
--   select vault.create_secret('<valeur de CRON_SECRET>', 'cron_secret');
-- Sans ces secrets, les tâches HTTP ne font rien ; les tâches SQL tournent.
-- =============================================================================

create or replace function private.invoke_edge_function(p_name text, p_body jsonb default '{}'::jsonb)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  base_url text := private.get_secret('project_url');
  secret text := private.get_secret('cron_secret');
begin
  if base_url is null or secret is null then
    return null;
  end if;
  return net.http_post(
    url := rtrim(base_url, '/') || '/functions/v1/' || p_name,
    body := p_body,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', secret),
    timeout_milliseconds := 30000
  );
end;
$$;

-- Rétention des données sensibles et nettoyage.
create or replace function private.purge_retention()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Partages manuels expirés.
  update public.location_shares set ended_at = greatest(started_at, expires_at)
   where ended_at is null and expires_at is not null and expires_at <= now();
  -- Positions : 7 jours hors SOS, 90 jours pour les SOS.
  delete from public.location_points where sos_event_id is null and created_at < now() - interval '7 days';
  delete from public.location_points where sos_event_id is not null and created_at < now() - interval '90 days';
  update public.sos_events set last_location = null, last_accuracy_m = null
   where last_location is not null and status <> 'active' and started_at < now() - interval '90 days';
  -- Signalements expirés, événements bruts d'appareils, journal d'audit.
  delete from public.risk_reports where expires_at < now() - interval '1 day';
  delete from public.device_events where received_at < now() - interval '30 days';
  delete from public.audit_log where created_at < now() - interval '365 days';
end;
$$;

-- Appareils silencieux depuis plus de 10 minutes → hors ligne + alerte.
create or replace function private.mark_devices_offline()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  d record;
  n int := 0;
begin
  for d in
    update public.devices set is_online = false
     where is_online and last_seen_at is not null and last_seen_at < now() - interval '10 minutes'
    returning id, home_id, type, name, room
  loop
    perform private.create_alert(
      null, d.home_id, 'device', 'info',
      case d.type when 'camera' then 'Caméra hors ligne' else 'Appareil hors ligne' end,
      d.name || ' ne répond plus. Vérifiez son alimentation et la connexion Wi-Fi.',
      coalesce(d.room, d.name), d.id, null, 'offline:' || d.id, null);
    n := n + 1;
  end loop;
  return n;
end;
$$;

select cron.schedule('jammtech-retention', '17 * * * *', $$select private.purge_retention()$$);
select cron.schedule('jammtech-devices-offline', '*/5 * * * *', $$select private.mark_devices_offline()$$);
select cron.schedule('jammtech-purge-recordings', '*/5 * * * *',
  $$select private.invoke_edge_function('purge-expired', '{}'::jsonb)
    where exists (select 1 from public.recordings where expires_at <= now())
       or exists (select 1 from private.storage_deletion_queue where attempts < 10)$$);
select cron.schedule('jammtech-notification-sweep', '* * * * *',
  $$select private.invoke_edge_function('send-notification', '{"sweep": true}'::jsonb)
    where exists (select 1 from public.security_alerts
                  where notified_at is null and created_at < now() - interval '30 seconds'
                    and created_at > now() - interval '1 hour')$$);
-- Historique pg_cron : 7 jours.
select cron.schedule('jammtech-cron-history', '42 3 * * *',
  $$delete from cron.job_run_details where end_time < now() - interval '7 days'$$);
