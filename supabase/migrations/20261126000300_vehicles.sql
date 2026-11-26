-- =============================================================================
-- Transport — Phase 2 : « Mes véhicules » (traceurs GPS)
-- =============================================================================
-- Modèle + ingestion générique. AUCUNE commande à distance (coupure moteur) :
-- hors périmètre tant qu'un cadre juridique et de sécurité n'est pas validé.
-- Couper un moteur en mouvement est dangereux.
-- =============================================================================

create table public.vehicles (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete cascade,
  type public.vehicle_type not null,
  plate text check (plate is null or plate ~ '^[A-Z0-9]{2,12}$'),
  brand_model text check (brand_model is null or length(brand_model) <= 80),
  color text check (color is null or length(color) <= 40),
  photo_path text check (photo_path is null or length(photo_path) <= 200),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index vehicles_owner_idx on public.vehicles (owner_id);
create trigger vehicles_updated_at before update on public.vehicles
  for each row execute function private.set_updated_at();

create table public.vehicle_members (
  vehicle_id uuid not null references public.vehicles (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.home_role not null default 'member',
  created_at timestamptz not null default now(),
  primary key (vehicle_id, user_id)
);
create index vehicle_members_user_idx on public.vehicle_members (user_id);

-- Règles d'alerte par véhicule (heures en Africa/Dakar).
create table public.vehicle_rules (
  vehicle_id uuid primary key references public.vehicles (id) on delete cascade,
  allowed_start time,
  allowed_end time,
  night_ignition_alert boolean not null default true,
  geofence_alert boolean not null default true,
  updated_at timestamptz not null default now(),
  check ((allowed_start is null) = (allowed_end is null))
);

create table public.vehicle_geofences (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 80),
  center_lat double precision not null check (center_lat between -90 and 90),
  center_lng double precision not null check (center_lng between -180 and 180),
  center extensions.geography(Point, 4326) generated always as (
    extensions.st_setsrid(extensions.st_makepoint(center_lng, center_lat), 4326)::extensions.geography
  ) stored,
  radius_m int not null check (radius_m between 50 and 50000),
  created_at timestamptz not null default now()
);
create index vehicle_geofences_vehicle_idx on public.vehicle_geofences (vehicle_id);

create table public.trackers (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references public.vehicles (id) on delete cascade,
  name text not null default 'Traceur' check (length(btrim(name)) between 1 and 80),
  model text not null default 'other' check (model in ('teltonika', 'concox', 'jimi', 'other')),
  imei text unique check (imei is null or imei ~ '^[0-9]{15}$'),
  is_online boolean not null default false,
  last_seen_at timestamptz,
  last_lat double precision,
  last_lng double precision,
  last_speed_kmh real,
  ignition boolean,
  external_power boolean,
  battery_level smallint check (battery_level is null or battery_level between 0 and 100),
  inside_geofence boolean,
  created_at timestamptz not null default now()
);
create index trackers_vehicle_idx on public.trackers (vehicle_id);

create table public.tracker_credentials (
  tracker_id uuid primary key references public.trackers (id) on delete cascade,
  secret_hash bytea not null,
  created_at timestamptz not null default now(),
  rotated_at timestamptz
);

create table public.tracker_events (
  id bigint generated always as identity primary key,
  tracker_id uuid not null references public.trackers (id) on delete cascade,
  external_id text not null check (length(external_id) between 1 and 128),
  type text not null check (length(type) between 1 and 32),
  payload jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now(),
  unique (tracker_id, external_id)
);
create index tracker_events_received_idx on public.tracker_events (received_at);

create table public.tracker_positions (
  id bigint generated always as identity primary key,
  tracker_id uuid not null references public.trackers (id) on delete cascade,
  vehicle_id uuid not null references public.vehicles (id) on delete cascade,
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  location extensions.geography(Point, 4326) generated always as (
    extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography
  ) stored,
  speed_kmh real,
  heading real,
  ignition boolean,
  recorded_at timestamptz not null,
  created_at timestamptz not null default now()
);
comment on table public.tracker_positions is 'Positions des traceurs : conservation 30 jours.';
create index tracker_positions_vehicle_idx on public.tracker_positions (vehicle_id, recorded_at desc);
create index tracker_positions_created_idx on public.tracker_positions (created_at);

-- Alertes véhicule dans le flux d'alertes existant.
alter table public.security_alerts add column vehicle_id uuid references public.vehicles (id) on delete cascade;
alter table public.security_alerts drop constraint security_alerts_check;
alter table public.security_alerts add constraint security_alerts_target_check
  check (user_id is not null or home_id is not null or vehicle_id is not null);
create index security_alerts_vehicle_idx on public.security_alerts (vehicle_id, created_at desc)
  where vehicle_id is not null;

-- -----------------------------------------------------------------------------
-- Aides et triggers
-- -----------------------------------------------------------------------------
create or replace function private.is_vehicle_member(p_vehicle uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.vehicle_members where vehicle_id = p_vehicle and user_id = auth.uid());
$$;

create or replace function private.is_vehicle_owner(p_vehicle uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.vehicle_members
                 where vehicle_id = p_vehicle and user_id = auth.uid() and role = 'owner');
$$;

create or replace function private.vehicles_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.plate := nullif(upper(regexp_replace(coalesce(new.plate, ''), '[^A-Za-z0-9]', '', 'g')), '');
  if new.photo_path is not null and new.photo_path !~ ('^' || new.owner_id || '/v_' || new.id || '\.(jpg|jpeg|png|webp)$') then
    raise exception 'Chemin de photo invalide (<owner_id>/v_<vehicle_id>.jpg)' using errcode = '22023';
  end if;
  return new;
end;
$$;
create trigger vehicles_before_write before insert or update on public.vehicles
  for each row execute function private.vehicles_before_write();

create or replace function private.vehicles_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.vehicle_members (vehicle_id, user_id, role) values (new.id, new.owner_id, 'owner')
  on conflict do nothing;
  insert into public.vehicle_rules (vehicle_id) values (new.id) on conflict do nothing;
  return new;
end;
$$;
create trigger vehicles_after_insert after insert on public.vehicles
  for each row execute function private.vehicles_after_insert();

create or replace function private.vehicles_after_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.photo_path is not null then
    insert into private.storage_deletion_queue (bucket, path)
    values ('vehicle-photos', old.photo_path) on conflict do nothing;
  end if;
  return old;
end;
$$;
create trigger vehicles_after_delete after delete on public.vehicles
  for each row execute function private.vehicles_after_delete();

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.vehicles enable row level security;
alter table public.vehicle_members enable row level security;
alter table public.vehicle_rules enable row level security;
alter table public.vehicle_geofences enable row level security;
alter table public.trackers enable row level security;
alter table public.tracker_credentials enable row level security;
alter table public.tracker_events enable row level security;
alter table public.tracker_positions enable row level security;

revoke all on public.vehicles, public.vehicle_members, public.vehicle_rules, public.vehicle_geofences,
  public.trackers, public.tracker_credentials, public.tracker_events, public.tracker_positions
  from anon, authenticated;
grant all on public.vehicles, public.vehicle_members, public.vehicle_rules, public.vehicle_geofences,
  public.trackers, public.tracker_credentials, public.tracker_events, public.tracker_positions
  to service_role;

grant select, delete on public.vehicles to authenticated;
grant insert (id, owner_id, type, plate, brand_model, color, photo_path) on public.vehicles to authenticated;
grant update (type, plate, brand_model, color, photo_path) on public.vehicles to authenticated;
create policy vehicles_select on public.vehicles
  for select to authenticated using (private.is_vehicle_member(id));
create policy vehicles_insert on public.vehicles
  for insert to authenticated with check (owner_id = (select auth.uid()));
create policy vehicles_update on public.vehicles
  for update to authenticated using (private.is_vehicle_owner(id)) with check (private.is_vehicle_owner(id));
create policy vehicles_delete on public.vehicles
  for delete to authenticated using (private.is_vehicle_owner(id));

grant select, delete on public.vehicle_members to authenticated;
create policy vehicle_members_select on public.vehicle_members
  for select to authenticated using (private.is_vehicle_member(vehicle_id));
create policy vehicle_members_delete on public.vehicle_members
  for delete to authenticated
  using ((private.is_vehicle_owner(vehicle_id) and user_id <> (select auth.uid())) or (user_id = (select auth.uid()) and role <> 'owner'));

grant select on public.vehicle_rules to authenticated;
grant update (allowed_start, allowed_end, night_ignition_alert, geofence_alert) on public.vehicle_rules to authenticated;
create policy vehicle_rules_select on public.vehicle_rules
  for select to authenticated using (private.is_vehicle_member(vehicle_id));
create policy vehicle_rules_update on public.vehicle_rules
  for update to authenticated using (private.is_vehicle_owner(vehicle_id)) with check (private.is_vehicle_owner(vehicle_id));

grant select, delete on public.vehicle_geofences to authenticated;
grant insert (vehicle_id, name, center_lat, center_lng, radius_m) on public.vehicle_geofences to authenticated;
grant update (name, center_lat, center_lng, radius_m) on public.vehicle_geofences to authenticated;
create policy vehicle_geofences_select on public.vehicle_geofences
  for select to authenticated using (private.is_vehicle_member(vehicle_id));
create policy vehicle_geofences_insert on public.vehicle_geofences
  for insert to authenticated with check (private.is_vehicle_owner(vehicle_id));
create policy vehicle_geofences_update on public.vehicle_geofences
  for update to authenticated using (private.is_vehicle_owner(vehicle_id)) with check (private.is_vehicle_owner(vehicle_id));
create policy vehicle_geofences_delete on public.vehicle_geofences
  for delete to authenticated using (private.is_vehicle_owner(vehicle_id));

grant select, delete on public.trackers to authenticated;
grant update (name) on public.trackers to authenticated;
create policy trackers_select on public.trackers
  for select to authenticated using (private.is_vehicle_member(vehicle_id));
create policy trackers_update on public.trackers
  for update to authenticated using (private.is_vehicle_owner(vehicle_id)) with check (private.is_vehicle_owner(vehicle_id));
create policy trackers_delete on public.trackers
  for delete to authenticated using (private.is_vehicle_owner(vehicle_id));

grant select on public.tracker_positions to authenticated;
create policy tracker_positions_select on public.tracker_positions
  for select to authenticated using (private.is_vehicle_member(vehicle_id));
-- tracker_credentials, tracker_events : aucun accès client.

-- Alertes : les membres du véhicule voient ses alertes.
drop policy security_alerts_select on public.security_alerts;
create policy security_alerts_select on public.security_alerts
  for select to authenticated
  using (user_id = (select auth.uid())
         or (home_id is not null and private.is_home_member(home_id))
         or (vehicle_id is not null and private.is_vehicle_member(vehicle_id)));

-- Photos de véhicule : membres du véhicule (chemin <owner>/v_<vehicle_id>.jpg).
create or replace function private.can_view_vehicle_photo(p_name text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  vid uuid;
begin
  begin
    vid := substring(p_name from '/v_([0-9a-f-]{36})\.(jpg|jpeg|png|webp)$')::uuid;
  exception when others then
    return false;
  end;
  return vid is not null and exists (
    select 1 from public.vehicle_members where vehicle_id = vid and user_id = auth.uid());
end;
$$;
create policy vehicle_photos_select_members on storage.objects
  for select to authenticated
  using (bucket_id = 'vehicle-photos' and private.can_view_vehicle_photo(name));

-- -----------------------------------------------------------------------------
-- RPC
-- -----------------------------------------------------------------------------
create or replace function public.register_tracker(
  p_vehicle_id uuid,
  p_name text default 'Traceur',
  p_model text default 'other',
  p_imei text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  t public.trackers;
  secret text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if not private.is_vehicle_owner(p_vehicle_id) then
    raise exception 'Seul le propriétaire peut ajouter un traceur' using errcode = '42501';
  end if;
  if (select count(*) from public.trackers where vehicle_id = p_vehicle_id) >= 3 then
    raise exception 'Nombre maximal de traceurs atteint' using errcode = 'P0001';
  end if;
  insert into public.trackers (vehicle_id, name, model, imei)
  values (p_vehicle_id, btrim(coalesce(p_name, 'Traceur')), coalesce(p_model, 'other'), p_imei)
  returning * into t;
  insert into public.tracker_credentials (tracker_id, secret_hash) values (t.id, extensions.digest(secret, 'sha256'));
  perform private.audit('tracker.registered', auth.uid(), 'trackers', t.id::text,
    jsonb_build_object('vehicle_id', p_vehicle_id));
  return jsonb_build_object('tracker', to_jsonb(t), 'ingest_token', t.id::text || '.' || secret);
end;
$$;

create or replace function public.rotate_tracker_secret(p_tracker_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  vid uuid;
  secret text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  select vehicle_id into vid from public.trackers where id = p_tracker_id;
  if vid is null or not private.is_vehicle_owner(vid) then
    raise exception 'Traceur introuvable' using errcode = '42501';
  end if;
  update public.tracker_credentials set secret_hash = extensions.digest(secret, 'sha256'), rotated_at = now()
   where tracker_id = p_tracker_id;
  return p_tracker_id::text || '.' || secret;
end;
$$;

create or replace function public.add_vehicle_member(p_vehicle_id uuid, p_phone text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  target uuid;
begin
  if not private.is_vehicle_owner(p_vehicle_id) then
    raise exception 'Seul le propriétaire peut partager ce véhicule' using errcode = '42501';
  end if;
  select p.id into target from public.profiles p join auth.users u on u.id = p.id
  where p.phone = private.normalize_phone(p_phone) and u.phone_confirmed_at is not null;
  if target is null then
    raise exception 'Aucun compte JammTech vérifié pour ce numéro' using errcode = 'P0002';
  end if;
  insert into public.vehicle_members (vehicle_id, user_id, role) values (p_vehicle_id, target, 'member')
  on conflict do nothing;
  return true;
end;
$$;

-- Service : authentification d'un traceur + contexte (règles, zones).
create or replace function public.svc_authenticate_tracker(p_tracker_id uuid, p_secret text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'tracker', to_jsonb(t),
    'vehicle', jsonb_build_object('id', v.id, 'owner_id', v.owner_id, 'type', v.type, 'plate', v.plate,
                                  'brand_model', v.brand_model),
    'rules', to_jsonb(r) - 'vehicle_id' - 'updated_at',
    'geofences', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'lat', g.center_lat,
                                                               'lng', g.center_lng, 'radius_m', g.radius_m))
                           from public.vehicle_geofences g where g.vehicle_id = v.id), '[]'::jsonb))
  from public.trackers t
  join public.tracker_credentials c on c.tracker_id = t.id
  join public.vehicles v on v.id = t.vehicle_id
  left join public.vehicle_rules r on r.vehicle_id = v.id
  where t.id = p_tracker_id and c.secret_hash = extensions.digest(p_secret, 'sha256');
$$;

create or replace function public.svc_create_vehicle_alert(
  p_vehicle_id uuid,
  p_severity public.alert_severity,
  p_title text,
  p_description text,
  p_dedupe_key text default null,
  p_lat double precision default null,
  p_lng double precision default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_id uuid;
begin
  insert into public.security_alerts (vehicle_id, category, severity, title, description, location_label,
                                      dedupe_key, location)
  values (p_vehicle_id, 'vehicle', p_severity, p_title, coalesce(p_description, ''),
          (select coalesce(nullif(concat_ws(' ', brand_model, plate), ''), 'Véhicule') from public.vehicles where id = p_vehicle_id),
          p_dedupe_key,
          case when p_lat is null then null
               else extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography end)
  on conflict (dedupe_key) where dedupe_key is not null and resolved_at is null do nothing
  returning id into new_id;
  return new_id;
end;
$$;

-- Destinataires d'une alerte : utilisateur, membres de la maison, membres du véhicule.
create or replace function public.svc_alert_recipients(p_alert_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with a as (select * from public.security_alerts where id = p_alert_id),
  users as (
    select a.user_id as uid from a where a.user_id is not null
    union
    select hm.user_id from a join public.home_members hm on hm.home_id = a.home_id
    union
    select vm.user_id from a join public.vehicle_members vm on vm.vehicle_id = a.vehicle_id
  )
  select jsonb_build_object(
    'alert', (select to_jsonb(a) - 'location' from a),
    'recipients', coalesce(jsonb_agg(jsonb_build_object(
      'user_id', u.uid,
      'phone', p.phone,
      'language', p.language,
      'preferences', to_jsonb(np) - 'user_id' - 'updated_at',
      'push_tokens', coalesce((select jsonb_agg(jsonb_build_object('token', pt.token, 'platform', pt.platform))
                               from public.push_tokens pt where pt.user_id = u.uid), '[]'::jsonb)
    )), '[]'::jsonb)
  )
  from users u
  join public.profiles p on p.id = u.uid
  left join public.notification_preferences np on np.user_id = u.uid;
$$;

-- Marquer / tout marquer comme traité : inclut les alertes véhicule.
create or replace function public.resolve_alert(p_alert_id uuid, p_resolved boolean default true)
returns public.security_alerts
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.security_alerts;
begin
  select * into a from public.security_alerts where id = p_alert_id;
  if not found or not (a.user_id = auth.uid()
                       or (a.home_id is not null and private.is_home_member(a.home_id))
                       or (a.vehicle_id is not null and private.is_vehicle_member(a.vehicle_id))) then
    raise exception 'Alerte introuvable' using errcode = '42501';
  end if;
  update public.security_alerts
     set resolved_at = case when p_resolved then coalesce(resolved_at, now()) end,
         resolved_by = case when p_resolved then coalesce(resolved_by, auth.uid()) end
   where id = p_alert_id
   returning * into a;
  return a;
end;
$$;

create or replace function public.resolve_all_alerts()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  n int;
begin
  update public.security_alerts a
     set resolved_at = now(), resolved_by = auth.uid()
   where a.resolved_at is null
     and (a.user_id = auth.uid()
          or a.home_id in (select home_id from public.home_members where user_id = auth.uid())
          or a.vehicle_id in (select vehicle_id from public.vehicle_members where user_id = auth.uid()));
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Résumé transport (écran Transport) : un aller-retour.
create or replace function public.get_transport_summary()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'active_trip', (select private.trip_snapshot(t) || jsonb_build_object(
                      'checkin_pending', t.checkin_round > 0, 'last_location_at', t.last_location_at)
                    from public.trips t
                    where t.user_id = auth.uid() and t.ended_at is null and t.status in ('active', 'escalated')
                    order by t.started_at desc limit 1),
    'watched_trips', public.get_trips_i_watch(),
    'recent_trips', coalesce((select jsonb_agg(x order by x ->> 'started_at' desc) from (
                      select private.trip_snapshot(t) as x from public.trips t
                      where t.user_id = auth.uid() and t.ended_at is not null
                      order by t.started_at desc limit 10) s), '[]'::jsonb),
    'vehicles', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', v.id, 'type', v.type, 'plate', v.plate, 'brand_model', v.brand_model, 'color', v.color,
                  'photo_path', v.photo_path, 'role', vm.role,
                  'trackers', coalesce((select jsonb_agg(jsonb_build_object(
                      'id', tk.id, 'name', tk.name, 'is_online', tk.is_online, 'last_seen_at', tk.last_seen_at,
                      'ignition', tk.ignition, 'battery_level', tk.battery_level,
                      'last_lat', tk.last_lat, 'last_lng', tk.last_lng, 'last_speed_kmh', tk.last_speed_kmh))
                    from public.trackers tk where tk.vehicle_id = v.id), '[]'::jsonb)))
                from public.vehicles v join public.vehicle_members vm on vm.vehicle_id = v.id
                where vm.user_id = auth.uid()), '[]'::jsonb)
  );
$$;

-- -----------------------------------------------------------------------------
-- Rétention (version finale) et traceurs hors ligne
-- -----------------------------------------------------------------------------
create or replace function private.purge_retention()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.location_shares set ended_at = greatest(started_at, expires_at)
   where ended_at is null and expires_at is not null and expires_at <= now();
  delete from public.location_points
   where sos_event_id is null and trip_id is null and created_at < now() - interval '7 days';
  delete from public.location_points
   where sos_event_id is null and trip_id is not null and created_at < now() - interval '30 days';
  delete from public.location_points where sos_event_id is not null and created_at < now() - interval '90 days';
  update public.sos_events set last_location = null, last_accuracy_m = null
   where last_location is not null and status <> 'active' and started_at < now() - interval '90 days';
  delete from public.trips
   where ended_at is not null and sos_event_id is null and started_at < now() - interval '30 days';
  delete from public.trips
   where ended_at is not null and sos_event_id is not null and started_at < now() - interval '90 days';
  delete from public.tracker_positions where created_at < now() - interval '30 days';
  delete from public.tracker_events where received_at < now() - interval '30 days';
  delete from public.risk_reports where expires_at < now() - interval '1 day';
  delete from public.device_events where received_at < now() - interval '30 days';
  delete from public.audit_log where created_at < now() - interval '365 days';
end;
$$;

create or replace function private.mark_trackers_offline()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  t record;
  n int := 0;
begin
  for t in
    update public.trackers set is_online = false
     where is_online and last_seen_at < now() - interval '30 minutes'
    returning id, vehicle_id, name
  loop
    perform public.svc_create_vehicle_alert(t.vehicle_id, 'warning', 'Traceur hors ligne',
      t.name || ' ne communique plus depuis 30 minutes.', 'tracker_offline:' || t.id);
    n := n + 1;
  end loop;
  return n;
end;
$$;
select cron.schedule('jammtech-trackers-offline', '*/5 * * * *', $$select private.mark_trackers_offline()$$);

-- Export : véhicules ajoutés.
create or replace function public.export_my_data()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception 'Authentification requise' using errcode = '42501';
  end if;
  return public.export_my_data_core() || jsonb_build_object(
    'trips', (select coalesce(jsonb_agg(to_jsonb(t) - 'origin' - 'destination' - 'route'), '[]')
              from public.trips t where t.user_id = uid),
    'trip_events', (select coalesce(jsonb_agg(jsonb_build_object('trip_id', e.trip_id, 'type', e.type,
                      'created_at', e.created_at)), '[]')
                    from public.trip_events e where e.user_id = uid and e.type <> 'checkin_duress'),
    'vehicles', (select coalesce(jsonb_agg(jsonb_build_object('vehicle', to_jsonb(v), 'role', vm.role,
                   'trackers', (select coalesce(jsonb_agg(to_jsonb(t) - 'inside_geofence'), '[]')
                                from public.trackers t where t.vehicle_id = v.id))), '[]')
                 from public.vehicles v join public.vehicle_members vm on vm.vehicle_id = v.id
                 where vm.user_id = uid)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Droits
-- -----------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon, authenticated;
grant execute on all functions in schema private to service_role;
grant execute on function
  private.is_trusted_contact_of(uuid, uuid),
  private.has_active_location_window(uuid),
  private.can_view_location(uuid, uuid),
  private.can_receive_topic(text),
  private.is_home_member(uuid),
  private.is_home_owner(uuid),
  private.is_valid_phone(text),
  private.can_view_avatar(text),
  private.normalize_phone(text),
  private.is_trip_watcher(uuid, uuid),
  private.can_view_trip(uuid, uuid),
  private.is_trip_owner(uuid),
  private.trip_id_from_photo_path(text),
  private.is_vehicle_member(uuid),
  private.is_vehicle_owner(uuid),
  private.can_view_vehicle_photo(text)
to authenticated;

grant execute on function
  public.register_tracker(uuid, text, text, text),
  public.rotate_tracker_secret(uuid),
  public.add_vehicle_member(uuid, text),
  public.get_transport_summary(),
  public.resolve_alert(uuid, boolean),
  public.resolve_all_alerts(),
  public.export_my_data()
to authenticated;

revoke execute on function
  public.svc_authenticate_tracker(uuid, text),
  public.svc_create_vehicle_alert(uuid, public.alert_severity, text, text, text, double precision, double precision),
  public.svc_alert_recipients(uuid)
from authenticated;
grant execute on function
  public.svc_authenticate_tracker(uuid, text),
  public.svc_create_vehicle_alert(uuid, public.alert_severity, text, text, text, double precision, double precision),
  public.svc_alert_recipients(uuid)
to service_role;
