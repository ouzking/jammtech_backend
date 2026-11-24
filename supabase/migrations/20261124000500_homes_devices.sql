-- =============================================================================
-- Incrément 5 — Maison et appareils
-- =============================================================================

create table public.homes (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Résidence principale' check (length(btrim(name)) between 1 and 100),
  arm_mode public.arm_mode not null default 'disarmed',
  arm_mode_changed_at timestamptz not null default now(),
  arm_mode_changed_by uuid references auth.users (id) on delete set null,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger homes_updated_at before update on public.homes
  for each row execute function private.set_updated_at();

create table public.home_members (
  home_id uuid not null references public.homes (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.home_role not null default 'member',
  created_at timestamptz not null default now(),
  primary key (home_id, user_id)
);
create index home_members_user_idx on public.home_members (user_id);

-- Journal des changements de mode d'armement : qui, quand, depuis quel appareil.
create table public.arm_mode_log (
  id bigint generated always as identity primary key,
  home_id uuid not null references public.homes (id) on delete cascade,
  mode public.arm_mode not null,
  previous_mode public.arm_mode,
  changed_by uuid references auth.users (id) on delete set null,
  client_device text check (client_device is null or length(client_device) <= 120),
  changed_at timestamptz not null default now()
);
create index arm_mode_log_home_idx on public.arm_mode_log (home_id, changed_at desc);

create table public.devices (
  id uuid primary key default gen_random_uuid(),
  home_id uuid not null references public.homes (id) on delete cascade,
  type public.device_type not null,
  name text not null check (length(btrim(name)) between 1 and 100),
  room text check (room is null or length(room) <= 100),
  is_on boolean not null default false,
  is_online boolean not null default false,
  last_seen_at timestamptz,
  firmware_version text check (firmware_version is null or length(firmware_version) <= 50),
  -- État remonté par l'appareil (ex. {"open": true} pour un capteur de porte,
  -- {"battery": 80}). Prévu aussi pour le direct vidéo : {"stream_url": ...}.
  state jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index devices_home_idx on public.devices (home_id, type);
create trigger devices_updated_at before update on public.devices
  for each row execute function private.set_updated_at();

-- Identifiants d'ingestion des appareils (webhook `device-event`).
-- Seule l'empreinte SHA-256 du secret est stockée.
create table public.device_credentials (
  device_id uuid primary key references public.devices (id) on delete cascade,
  secret_hash bytea not null,
  created_at timestamptz not null default now(),
  rotated_at timestamptz
);

-- Événements bruts reçus des appareils (dédoublonnage + diagnostic, 30 jours).
create table public.device_events (
  id bigint generated always as identity primary key,
  device_id uuid not null references public.devices (id) on delete cascade,
  home_id uuid not null references public.homes (id) on delete cascade,
  external_id text not null check (length(external_id) between 1 and 128),
  type text not null check (length(type) between 1 and 64),
  payload jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now(),
  unique (device_id, external_id)
);
create index device_events_received_idx on public.device_events (received_at);

-- -----------------------------------------------------------------------------
-- Aides d'appartenance
-- -----------------------------------------------------------------------------
create or replace function private.is_home_member(p_home uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.home_members where home_id = p_home and user_id = auth.uid());
$$;
grant execute on function private.is_home_member(uuid) to authenticated;

create or replace function private.is_home_owner(p_home uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.home_members where home_id = p_home and user_id = auth.uid() and role = 'owner'
  );
$$;
grant execute on function private.is_home_owner(uuid) to authenticated;

-- Le créateur d'une maison en devient propriétaire.
create or replace function private.homes_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.created_by is not null then
    insert into public.home_members (home_id, user_id, role)
    values (new.id, new.created_by, 'owner')
    on conflict do nothing;
  end if;
  return new;
end;
$$;
create trigger homes_after_insert after insert on public.homes
  for each row execute function private.homes_after_insert();

-- Une maison garde toujours au moins un propriétaire.
create or replace function private.home_members_keep_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.role = 'owner'
     and (tg_op = 'DELETE' or new.role <> 'owner')
     and exists (select 1 from public.homes where id = old.home_id)
     and not exists (
       select 1 from public.home_members
       where home_id = old.home_id and role = 'owner' and user_id <> old.user_id
     ) then
    raise exception 'Une maison doit garder au moins un propriétaire' using errcode = 'P0001';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
create trigger home_members_keep_owner before update or delete on public.home_members
  for each row execute function private.home_members_keep_owner();

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.homes enable row level security;
alter table public.home_members enable row level security;
alter table public.arm_mode_log enable row level security;
alter table public.devices enable row level security;
alter table public.device_credentials enable row level security;
alter table public.device_events enable row level security;

revoke all on public.homes, public.home_members, public.arm_mode_log, public.devices,
  public.device_credentials, public.device_events from anon, authenticated;
grant all on public.homes, public.home_members, public.arm_mode_log, public.devices,
  public.device_credentials, public.device_events to service_role;

-- homes : création libre (le créateur devient propriétaire), renommage par un
-- propriétaire. Le mode d'armement ne change QUE via `set_arm_mode()` /
-- la fonction Edge `disarm`.
grant select, delete on public.homes to authenticated;
grant insert (name, created_by) on public.homes to authenticated;
grant update (name) on public.homes to authenticated;
create policy homes_select_member on public.homes
  for select to authenticated using (private.is_home_member(id));
create policy homes_insert_self on public.homes
  for insert to authenticated with check (created_by = (select auth.uid()));
create policy homes_update_owner on public.homes
  for update to authenticated using (private.is_home_owner(id)) with check (private.is_home_owner(id));
create policy homes_delete_owner on public.homes
  for delete to authenticated using (private.is_home_owner(id));

-- home_members : visibles par les membres ; gérés par les propriétaires ; un
-- membre peut se retirer lui-même.
grant select, delete on public.home_members to authenticated;
grant update (role) on public.home_members to authenticated;
create policy home_members_select on public.home_members
  for select to authenticated using (private.is_home_member(home_id));
create policy home_members_update_owner on public.home_members
  for update to authenticated using (private.is_home_owner(home_id)) with check (private.is_home_owner(home_id));
create policy home_members_delete on public.home_members
  for delete to authenticated
  using (private.is_home_owner(home_id) or user_id = (select auth.uid()));

grant select on public.arm_mode_log to authenticated;
create policy arm_mode_log_select_member on public.arm_mode_log
  for select to authenticated using (private.is_home_member(home_id));

-- devices : lecture par les membres ; allumer / éteindre, renommer et changer
-- de pièce par les membres ; suppression par un propriétaire. La création passe
-- par `register_device()` (génération du secret d'ingestion).
grant select, delete on public.devices to authenticated;
grant update (is_on, name, room) on public.devices to authenticated;
create policy devices_select_member on public.devices
  for select to authenticated using (private.is_home_member(home_id));
create policy devices_update_member on public.devices
  for update to authenticated using (private.is_home_member(home_id)) with check (private.is_home_member(home_id));
create policy devices_delete_owner on public.devices
  for delete to authenticated using (private.is_home_owner(home_id));

-- device_credentials, device_events : aucun accès client.

-- -----------------------------------------------------------------------------
-- RPC
-- -----------------------------------------------------------------------------

-- Changement de mode d'armement vers `home` ou `away`. Le désarmement passe
-- par la fonction Edge `disarm` (vérification du code / code de contrainte).
-- Renvoie le nouvel état et les avertissements (porte ouverte, caméra hors
-- ligne, serrure ouverte…).
create or replace function public.set_arm_mode(
  p_home_id uuid,
  p_mode public.arm_mode,
  p_client_device text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  h public.homes;
  warnings jsonb;
begin
  if uid is null or not private.is_home_member(p_home_id) then
    raise exception 'Maison introuvable' using errcode = '42501';
  end if;
  if p_mode = 'disarmed' then
    raise exception 'Le désarmement passe par la fonction disarm' using errcode = '22023';
  end if;

  select coalesce(jsonb_agg(w), '[]'::jsonb) into warnings
  from (
    select jsonb_build_object('device_id', d.id, 'name', d.name, 'room', d.room, 'code', 'device_offline',
                              'message', d.name || ' est hors ligne') as w
    from public.devices d
    where d.home_id = p_home_id and d.type in ('camera', 'sensor', 'siren', 'lock') and not d.is_online
    union all
    select jsonb_build_object('device_id', d.id, 'name', d.name, 'room', d.room, 'code', 'sensor_open',
                              'message', d.name || ' est ouvert(e)')
    from public.devices d
    where d.home_id = p_home_id and d.type = 'sensor' and coalesce((d.state ->> 'open')::boolean, false)
    union all
    select jsonb_build_object('device_id', d.id, 'name', d.name, 'room', d.room, 'code', 'lock_unlocked',
                              'message', d.name || ' n''est pas verrouillée')
    from public.devices d
    where p_mode = 'away' and d.home_id = p_home_id and d.type = 'lock' and d.is_online and not d.is_on
  ) s;

  -- Les avertissements détaillés ne concernent que le mode Absence.
  if p_mode <> 'away' then
    warnings := '[]'::jsonb;
  end if;

  h := private.apply_arm_mode(p_home_id, p_mode, uid, p_client_device);

  return jsonb_build_object(
    'home_id', h.id, 'arm_mode', h.arm_mode, 'arm_mode_changed_at', h.arm_mode_changed_at,
    'warnings', warnings
  );
end;
$$;

create or replace function private.apply_arm_mode(
  p_home_id uuid,
  p_mode public.arm_mode,
  p_user uuid,
  p_client_device text
)
returns public.homes
language plpgsql
security definer
set search_path = ''
as $$
declare
  prev public.arm_mode;
  h public.homes;
begin
  select arm_mode into prev from public.homes where id = p_home_id for update;
  update public.homes
     set arm_mode = p_mode, arm_mode_changed_at = now(), arm_mode_changed_by = p_user
   where id = p_home_id
   returning * into h;
  insert into public.arm_mode_log (home_id, mode, previous_mode, changed_by, client_device)
  values (p_home_id, p_mode, prev, p_user, left(p_client_device, 120));
  perform private.broadcast('home:' || p_home_id, 'arm_mode', jsonb_build_object(
    'home_id', p_home_id, 'arm_mode', p_mode, 'changed_at', h.arm_mode_changed_at, 'changed_by', p_user));
  return h;
end;
$$;
grant execute on function public.set_arm_mode(uuid, public.arm_mode, text) to authenticated;

-- Désarmement après vérification du code par la fonction Edge `disarm`.
create or replace function public.svc_disarm_home(p_home_id uuid, p_user_id uuid, p_client_device text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  h public.homes;
begin
  if not exists (select 1 from public.home_members where home_id = p_home_id and user_id = p_user_id) then
    return null;
  end if;
  h := private.apply_arm_mode(p_home_id, 'disarmed', p_user_id, p_client_device);
  return jsonb_build_object(
    'home_id', h.id, 'arm_mode', h.arm_mode, 'arm_mode_changed_at', h.arm_mode_changed_at,
    'warnings', '[]'::jsonb);
end;
$$;
revoke execute on function public.svc_disarm_home(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.svc_disarm_home(uuid, uuid, text) to service_role;

-- Enregistre un nouvel appareil et renvoie, UNE SEULE FOIS, son secret
-- d'ingestion (à saisir dans l'appareil / la passerelle).
create or replace function public.register_device(
  p_home_id uuid,
  p_type public.device_type,
  p_name text,
  p_room text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.devices;
  secret text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if not private.is_home_owner(p_home_id) then
    raise exception 'Seul un propriétaire peut ajouter un appareil' using errcode = '42501';
  end if;
  if (select count(*) from public.devices where home_id = p_home_id) >= 50 then
    raise exception 'Nombre maximal d''appareils atteint' using errcode = 'P0001';
  end if;
  insert into public.devices (home_id, type, name, room)
  values (p_home_id, p_type, btrim(p_name), p_room)
  returning * into d;
  insert into public.device_credentials (device_id, secret_hash)
  values (d.id, extensions.digest(secret, 'sha256'));
  perform private.audit('device.registered', auth.uid(), 'devices', d.id::text, jsonb_build_object('home_id', p_home_id));
  return jsonb_build_object('device', to_jsonb(d), 'ingest_token', d.id::text || '.' || secret);
end;
$$;
grant execute on function public.register_device(uuid, public.device_type, text, text) to authenticated;

create or replace function public.rotate_device_secret(p_device_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  hid uuid;
  secret text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  select home_id into hid from public.devices where id = p_device_id;
  if hid is null or not private.is_home_owner(hid) then
    raise exception 'Appareil introuvable' using errcode = '42501';
  end if;
  update public.device_credentials
     set secret_hash = extensions.digest(secret, 'sha256'), rotated_at = now()
   where device_id = p_device_id;
  return p_device_id::text || '.' || secret;
end;
$$;
grant execute on function public.rotate_device_secret(uuid) to authenticated;

-- Authentifie un appareil (jeton « <device_id>.<secret> »). Service uniquement.
create or replace function public.svc_authenticate_device(p_device_id uuid, p_secret text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('device_id', d.id, 'home_id', d.home_id, 'type', d.type, 'name', d.name,
                            'room', d.room, 'is_online', d.is_online)
  from public.devices d
  join public.device_credentials c on c.device_id = d.id
  where d.id = p_device_id
    and c.secret_hash = extensions.digest(p_secret, 'sha256');
$$;
revoke execute on function public.svc_authenticate_device(uuid, text) from public, anon, authenticated;
grant execute on function public.svc_authenticate_device(uuid, text) to service_role;

-- Invitation d'un membre par numéro de téléphone (il doit avoir un compte).
create or replace function public.add_home_member(p_home_id uuid, p_phone text, p_role public.home_role default 'member')
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  target uuid;
begin
  if not private.is_home_owner(p_home_id) then
    raise exception 'Seul un propriétaire peut ajouter un membre' using errcode = '42501';
  end if;
  select p.id into target from public.profiles p
  join auth.users u on u.id = p.id
  where p.phone = private.normalize_phone(p_phone) and u.phone_confirmed_at is not null;
  if target is null then
    raise exception 'Aucun compte JammTech vérifié pour ce numéro' using errcode = 'P0002';
  end if;
  insert into public.home_members (home_id, user_id, role) values (p_home_id, target, p_role)
  on conflict (home_id, user_id) do update set role = excluded.role;
  return true;
end;
$$;
grant execute on function public.add_home_member(uuid, text, public.home_role) to authenticated;
