-- =============================================================================
-- Incrément 1 — Auth et profils
--   profiles, user_settings, notification_preferences, push_tokens,
--   security_codes, sessions (appareils connectés).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- profiles (1–1 avec auth.users)
-- -----------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null default '' check (length(full_name) <= 100),
  phone text unique check (phone is null or private.is_valid_phone(phone)),
  avatar_url text check (avatar_url is null or length(avatar_url) <= 512),
  language public.app_language not null default 'fr',
  plan text not null default 'free' check (plan in ('free', 'premium')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
comment on column public.profiles.phone is
  'Numéro E.164 vérifié par OTP. Synchronisé depuis auth.users, non modifiable par le client.';
comment on column public.profiles.avatar_url is
  'Chemin dans le bucket privé `avatars` (ex. <user_id>/avatar.jpg).';

create trigger profiles_updated_at before update on public.profiles
  for each row execute function private.set_updated_at();

alter table public.profiles enable row level security;
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
-- Le téléphone et le plan ne sont pas modifiables par le client.
grant update (full_name, avatar_url, language) on public.profiles to authenticated;
grant all on public.profiles to service_role;

create policy profiles_select_own on public.profiles
  for select to authenticated using (id = (select auth.uid()));
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- -----------------------------------------------------------------------------
-- user_settings
-- -----------------------------------------------------------------------------
create table public.user_settings (
  user_id uuid primary key references auth.users (id) on delete cascade,
  precise_location boolean not null default true,
  background_location boolean not null default false,
  auto_share_on_sos boolean not null default true,
  videos_wifi_only boolean not null default true,
  anonymous_stats boolean not null default false,
  updated_at timestamptz not null default now()
);
create trigger user_settings_updated_at before update on public.user_settings
  for each row execute function private.set_updated_at();

alter table public.user_settings enable row level security;
revoke all on public.user_settings from anon, authenticated;
grant select on public.user_settings to authenticated;
grant update (precise_location, background_location, auto_share_on_sos, videos_wifi_only, anonymous_stats)
  on public.user_settings to authenticated;
grant all on public.user_settings to service_role;

create policy user_settings_select_own on public.user_settings
  for select to authenticated using (user_id = (select auth.uid()));
create policy user_settings_update_own on public.user_settings
  for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- -----------------------------------------------------------------------------
-- notification_preferences
--   Un booléen par type (intrusions, zones, appareils, proches) et par canal.
--   Les heures calmes ne s'appliquent JAMAIS aux SOS ni aux alertes `critical`.
-- -----------------------------------------------------------------------------
create table public.notification_preferences (
  user_id uuid primary key references auth.users (id) on delete cascade,
  intrusions_push boolean not null default true,
  intrusions_sms boolean not null default true,
  zones_push boolean not null default true,
  zones_sms boolean not null default false,
  devices_push boolean not null default true,
  devices_sms boolean not null default false,
  contacts_push boolean not null default true,
  contacts_sms boolean not null default false,
  sound boolean not null default true,
  vibration boolean not null default true,
  quiet_hours_enabled boolean not null default false,
  quiet_hours_start time not null default '22:00',
  quiet_hours_end time not null default '07:00',
  updated_at timestamptz not null default now()
);
comment on column public.notification_preferences.quiet_hours_start is
  'Heure locale Africa/Dakar. Ignorée pour les SOS et les alertes critiques.';
create trigger notification_preferences_updated_at before update on public.notification_preferences
  for each row execute function private.set_updated_at();

alter table public.notification_preferences enable row level security;
revoke all on public.notification_preferences from anon, authenticated;
grant select on public.notification_preferences to authenticated;
grant update (
  intrusions_push, intrusions_sms, zones_push, zones_sms, devices_push, devices_sms,
  contacts_push, contacts_sms, sound, vibration, quiet_hours_enabled, quiet_hours_start, quiet_hours_end
) on public.notification_preferences to authenticated;
grant all on public.notification_preferences to service_role;

create policy notification_preferences_select_own on public.notification_preferences
  for select to authenticated using (user_id = (select auth.uid()));
create policy notification_preferences_update_own on public.notification_preferences
  for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- -----------------------------------------------------------------------------
-- push_tokens
-- -----------------------------------------------------------------------------
create table public.push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  token text not null unique check (length(token) between 10 and 4096),
  platform public.push_platform not null,
  device_label text check (length(device_label) <= 100),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index push_tokens_user_idx on public.push_tokens (user_id);
create trigger push_tokens_updated_at before update on public.push_tokens
  for each row execute function private.set_updated_at();

alter table public.push_tokens enable row level security;
revoke all on public.push_tokens from anon, authenticated;
grant select, delete on public.push_tokens to authenticated;
grant all on public.push_tokens to service_role;

create policy push_tokens_select_own on public.push_tokens
  for select to authenticated using (user_id = (select auth.uid()));
create policy push_tokens_delete_own on public.push_tokens
  for delete to authenticated using (user_id = (select auth.uid()));

-- Enregistrement d'un token : un token FCM appartient à un seul utilisateur à
-- la fois (changement de compte sur le même téléphone).
create or replace function public.register_push_token(
  p_token text,
  p_platform public.push_platform,
  p_device_label text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Authentification requise' using errcode = '42501';
  end if;
  if p_token is null or length(p_token) not between 10 and 4096 then
    raise exception 'Token push invalide' using errcode = '22023';
  end if;
  insert into public.push_tokens (user_id, token, platform, device_label)
  values (uid, p_token, p_platform, left(p_device_label, 100))
  on conflict (token) do update
    set user_id = excluded.user_id,
        platform = excluded.platform,
        device_label = excluded.device_label,
        updated_at = now();
end;
$$;
grant execute on function public.register_push_token(text, public.push_platform, text) to authenticated;

-- -----------------------------------------------------------------------------
-- security_codes : code de désarmement et code de contrainte, hachés (bcrypt).
--   Aucun accès client direct : uniquement via les RPC ci-dessous et la
--   fonction Edge `disarm`.
-- -----------------------------------------------------------------------------
create table public.security_codes (
  user_id uuid primary key references auth.users (id) on delete cascade,
  disarm_code_hash text,
  duress_code_hash text,
  failed_attempts int not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);
create trigger security_codes_updated_at before update on public.security_codes
  for each row execute function private.set_updated_at();

alter table public.security_codes enable row level security;
revoke all on public.security_codes from anon, authenticated;
grant all on public.security_codes to service_role;
-- Volontairement aucune politique pour `authenticated` : accès refusé.

create or replace function public.get_security_codes_status()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'has_disarm_code', coalesce(bool_or(disarm_code_hash is not null), false),
    'has_duress_code', coalesce(bool_or(duress_code_hash is not null), false)
  )
  from public.security_codes
  where user_id = auth.uid();
$$;
grant execute on function public.get_security_codes_status() to authenticated;

-- Définit ou change les codes. Si un code de désarmement existe déjà, il doit
-- être fourni (empêche un tiers ayant le téléphone déverrouillé de changer le
-- code de contrainte). Passer NULL pour un nouveau code le laisse inchangé ;
-- passer '' le supprime.
create or replace function public.set_security_codes(
  p_current_disarm_code text,
  p_new_disarm_code text default null,
  p_new_duress_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  cur public.security_codes;
  new_disarm text;
  new_duress text;
begin
  if uid is null then
    raise exception 'Authentification requise' using errcode = '42501';
  end if;

  insert into public.security_codes (user_id) values (uid) on conflict do nothing;
  select * into cur from public.security_codes where user_id = uid for update;

  if cur.locked_until is not null and cur.locked_until > now() then
    raise exception 'Trop de tentatives. Réessayez plus tard.' using errcode = 'P0001';
  end if;

  if cur.disarm_code_hash is not null
     and (p_current_disarm_code is null
          or extensions.crypt(p_current_disarm_code, cur.disarm_code_hash) <> cur.disarm_code_hash) then
    update public.security_codes
       set failed_attempts = failed_attempts + 1,
           locked_until = case when failed_attempts + 1 >= 5 then now() + interval '5 minutes' end
     where user_id = uid;
    raise exception 'Code actuel incorrect' using errcode = '28P01';
  end if;

  if p_new_disarm_code is not null and p_new_disarm_code <> '' and p_new_disarm_code !~ '^[0-9]{4,8}$' then
    raise exception 'Le code doit contenir de 4 à 8 chiffres' using errcode = '22023';
  end if;
  if p_new_duress_code is not null and p_new_duress_code <> '' and p_new_duress_code !~ '^[0-9]{4,8}$' then
    raise exception 'Le code de contrainte doit contenir de 4 à 8 chiffres' using errcode = '22023';
  end if;

  -- Valeurs effectives après modification, pour vérifier qu'elles diffèrent.
  new_disarm := coalesce(p_new_disarm_code, p_current_disarm_code);
  new_duress := p_new_duress_code;
  if new_duress is not null and new_duress <> '' and new_disarm is not null and new_duress = new_disarm then
    raise exception 'Le code de contrainte doit être différent du code de désarmement' using errcode = '22023';
  end if;
  if p_new_disarm_code is not null and p_new_disarm_code <> '' and p_new_duress_code is null
     and cur.duress_code_hash is not null
     and extensions.crypt(p_new_disarm_code, cur.duress_code_hash) = cur.duress_code_hash then
    raise exception 'Le code de désarmement doit être différent du code de contrainte' using errcode = '22023';
  end if;

  update public.security_codes
     set disarm_code_hash = case
           when p_new_disarm_code is null then disarm_code_hash
           when p_new_disarm_code = '' then null
           else extensions.crypt(p_new_disarm_code, extensions.gen_salt('bf', 10)) end,
         duress_code_hash = case
           when p_new_duress_code is null then duress_code_hash
           when p_new_duress_code = '' then null
           else extensions.crypt(p_new_duress_code, extensions.gen_salt('bf', 10)) end,
         failed_attempts = 0,
         locked_until = null
   where user_id = uid;

  perform private.audit('security_codes.updated', uid, 'security_codes', uid::text, '{}'::jsonb);
  return public.get_security_codes_status();
end;
$$;
grant execute on function public.set_security_codes(text, text, text) to authenticated;

-- Vérifie un code saisi au clavier de désarmement. Réservée au service.
-- Les DEUX comparaisons bcrypt sont toujours effectuées pour que le temps de
-- réponse ne révèle pas lequel des codes a été saisi.
-- Résultat : 'ok' | 'duress' | 'invalid' | 'locked' | 'no_code'.
create or replace function public.svc_verify_disarm_code(p_user_id uuid, p_code text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  cur public.security_codes;
  dummy constant text := '$2a$10$pUt2Xw7hfCKSZ.B1ifcgj.tDlyWl15c8xQD581pWTamM.Ltx7947S';
  is_disarm boolean;
  is_duress boolean;
begin
  select * into cur from public.security_codes where user_id = p_user_id for update;

  if not found or cur.disarm_code_hash is null then
    -- Aucun code configuré : pas de vérification possible côté serveur.
    -- Le code de contrainte reste vérifié s'il existe.
    if found and cur.duress_code_hash is not null and p_code is not null
       and extensions.crypt(p_code, cur.duress_code_hash) = cur.duress_code_hash then
      return 'duress';
    end if;
    return 'no_code';
  end if;

  if cur.locked_until is not null and cur.locked_until > now() then
    return 'locked';
  end if;

  is_disarm := p_code is not null and extensions.crypt(p_code, cur.disarm_code_hash) = cur.disarm_code_hash;
  is_duress := p_code is not null and extensions.crypt(p_code, coalesce(cur.duress_code_hash, dummy)) = cur.duress_code_hash;

  if is_duress then
    update public.security_codes set failed_attempts = 0, locked_until = null where user_id = p_user_id;
    return 'duress';
  elsif is_disarm then
    update public.security_codes set failed_attempts = 0, locked_until = null where user_id = p_user_id;
    return 'ok';
  end if;

  update public.security_codes
     set failed_attempts = failed_attempts + 1,
         locked_until = case when failed_attempts + 1 >= 5 then now() + interval '5 minutes' end
   where user_id = p_user_id;
  return 'invalid';
end;
$$;
revoke execute on function public.svc_verify_disarm_code(uuid, text) from public, anon, authenticated;
grant execute on function public.svc_verify_disarm_code(uuid, text) to service_role;

-- -----------------------------------------------------------------------------
-- Appareils connectés (sessions Supabase Auth)
-- -----------------------------------------------------------------------------
create or replace function public.list_my_sessions()
returns table (
  id uuid,
  created_at timestamptz,
  updated_at timestamptz,
  user_agent text,
  ip text,
  is_current boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select s.id, s.created_at, s.updated_at, s.user_agent, host(s.ip),
         s.id::text = coalesce(auth.jwt() ->> 'session_id', '')
  from auth.sessions s
  where s.user_id = auth.uid()
  order by s.updated_at desc nulls last;
$$;
grant execute on function public.list_my_sessions() to authenticated;

create or replace function public.revoke_session(p_session_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  deleted int;
begin
  if p_session_id::text = coalesce(auth.jwt() ->> 'session_id', '') then
    raise exception 'Utilisez la déconnexion pour la session courante' using errcode = '22023';
  end if;
  delete from auth.sessions where id = p_session_id and user_id = auth.uid();
  get diagnostics deleted = row_count;
  if deleted > 0 then
    perform private.audit('session.revoked', auth.uid(), 'sessions', p_session_id::text, '{}'::jsonb);
  end if;
  return deleted > 0;
end;
$$;
grant execute on function public.revoke_session(uuid) to authenticated;
