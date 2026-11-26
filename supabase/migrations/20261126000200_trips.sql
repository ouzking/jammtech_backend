-- =============================================================================
-- Transport — Phase 1 : « Trajet sécurisé »
-- =============================================================================
-- Règle absolue : l'ESCALADE EST FAITE PAR LE SERVEUR. Un téléphone volé,
-- éteint ou sans réseau ne peut ni l'empêcher ni la retarder : pg_cron
-- évalue chaque minute les trajets actifs (private.trip_watchdog_tick).
--
-- Flux des notifications : toute action qui doit prévenir quelqu'un écrit une
-- ligne dans trip_events (file d'envoi). L'Edge Function `trip-watchdog`
-- réclame ces lignes (verrou SKIP LOCKED, nouvel essai après 2 min) et envoie
-- push / SMS. Les fonctions Edge `trip-*` traitent leurs propres événements
-- immédiatement ; un trigger (pg_net) et pg_cron rattrapent le reste.
-- =============================================================================

-- Paramètres (modifiables ici, versionnés).
create or replace function private.trip_config()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'no_signal_minutes', 10,        -- aucune position depuis…
    'stopped_minutes', 10,          -- immobile depuis…
    'stopped_radius_m', 50,         -- … dans ce rayon
    'stopped_ignore_near_dest_m', 300,
    'deviation_m', 1000,            -- écart à l'itinéraire fourni
    'arrival_radius_m', 150,        -- arrivée automatique
    'snooze_minutes', 10,           -- après « Tout va bien » : pas de nouvelle question avant…
    'max_extensions', 3,
    'max_trip_hours', 24,
    'cancel_notify_after_minutes', 2
  )
$$;

-- -----------------------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------------------
create table public.trips (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  client_key uuid not null,
  status public.trip_status not null default 'active',
  mode public.trip_mode not null,
  origin_label text check (origin_label is null or length(origin_label) <= 200),
  origin_lat double precision check (origin_lat between -90 and 90),
  origin_lng double precision check (origin_lng between -180 and 180),
  origin extensions.geography(Point, 4326) generated always as (
    case when origin_lat is null or origin_lng is null then null
         else extensions.st_setsrid(extensions.st_makepoint(origin_lng, origin_lat), 4326)::extensions.geography end
  ) stored,
  destination_label text not null check (length(btrim(destination_label)) between 1 and 200),
  destination_lat double precision not null check (destination_lat between -90 and 90),
  destination_lng double precision not null check (destination_lng between -180 and 180),
  destination extensions.geography(Point, 4326) generated always as (
    extensions.st_setsrid(extensions.st_makepoint(destination_lng, destination_lat), 4326)::extensions.geography
  ) stored,
  -- Itinéraire prévu (facultatif) : sert à détecter un écart.
  route extensions.geography(LineString, 4326),
  expected_arrival_at timestamptz not null,
  grace_minutes smallint not null default 15 check (grace_minutes between 0 and 120),
  checkin_first_minutes smallint not null default 3 check (checkin_first_minutes between 1 and 15),
  checkin_second_minutes smallint not null default 2 check (checkin_second_minutes between 1 and 15),
  extensions_count smallint not null default 0,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  vehicle_plate text check (vehicle_plate is null or vehicle_plate ~ '^[A-Z0-9]{2,12}$'),
  vehicle_photo_path text check (vehicle_photo_path is null or length(vehicle_photo_path) <= 200),
  vehicle_note text check (vehicle_note is null or length(vehicle_note) <= 200),
  sos_event_id uuid references public.sos_events (id) on delete set null,
  last_lat double precision,
  last_lng double precision,
  last_accuracy_m real,
  last_location_at timestamptz,
  last_battery smallint check (last_battery is null or last_battery between 0 and 100),
  -- État de la surveillance (écrit uniquement par le serveur).
  checkin_round smallint not null default 0 check (checkin_round between 0 and 2),
  checkin_requested_at timestamptz,
  checkin_reason public.trip_event_type,
  checkin_snooze_until timestamptz,
  late_notified_at timestamptz,
  battery_notified_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, client_key),
  check (expected_arrival_at > started_at),
  check ((status in ('active', 'escalated')) = (ended_at is null) or status = 'escalated')
);
comment on table public.trips is
  'Trajets sécurisés. Conservation 30 jours (90 jours si rattachés à un SOS), photo du véhicule comprise.';
create unique index trips_one_active_idx on public.trips (user_id) where status = 'active';
create index trips_user_idx on public.trips (user_id, started_at desc);
create index trips_running_idx on public.trips (status) where ended_at is null;
create index trips_started_idx on public.trips (started_at);
create index trips_sos_idx on public.trips (sos_event_id) where sos_event_id is not null;

create table public.trip_watchers (
  trip_id uuid not null references public.trips (id) on delete cascade,
  contact_id uuid not null references public.trusted_contacts (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (trip_id, contact_id)
);
create index trip_watchers_contact_idx on public.trip_watchers (contact_id);

create table public.trip_events (
  id bigint generated always as identity primary key,
  trip_id uuid not null references public.trips (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  type public.trip_event_type not null,
  lat double precision,
  lng double precision,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  -- File d'envoi : null = à envoyer ; claimed = en cours ; dispatched = fait.
  dispatch_claimed_at timestamptz,
  dispatched_at timestamptz,
  dispatch_error text check (dispatch_error is null or length(dispatch_error) <= 500)
);
create index trip_events_trip_idx on public.trip_events (trip_id, created_at);
create index trip_events_pending_idx on public.trip_events (created_at) where dispatched_at is null;

-- Points de position rattachés à un trajet.
alter table public.location_points add column trip_id uuid references public.trips (id) on delete set null;
create index location_points_trip_idx on public.location_points (trip_id, recorded_at) where trip_id is not null;

-- -----------------------------------------------------------------------------
-- Aides de visibilité
-- -----------------------------------------------------------------------------
create or replace function private.is_trip_watcher(p_trip uuid, p_viewer uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.trip_watchers w
    join public.trusted_contacts tc on tc.id = w.contact_id
    where w.trip_id = p_trip and tc.contact_user_id = p_viewer
  );
$$;

-- Le voyageur voit toujours ses trajets ; un proche voit un trajet seulement
-- s'il en est watcher ET que le trajet est en cours.
create or replace function private.can_view_trip(p_trip uuid, p_viewer uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_viewer is not null and exists (
    select 1 from public.trips t
    where t.id = p_trip
      and (t.user_id = p_viewer
           or (t.ended_at is null and t.status in ('active', 'escalated')
               and private.is_trip_watcher(t.id, p_viewer)))
  );
$$;

create or replace function private.is_trip_owner(p_trip uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.trips where id = p_trip and user_id = auth.uid());
$$;

-- -----------------------------------------------------------------------------
-- RLS — aucune écriture directe par le client.
-- -----------------------------------------------------------------------------
alter table public.trips enable row level security;
alter table public.trip_watchers enable row level security;
alter table public.trip_events enable row level security;
revoke all on public.trips, public.trip_watchers, public.trip_events from anon, authenticated;
grant select on public.trips, public.trip_watchers, public.trip_events to authenticated;
grant all on public.trips, public.trip_watchers, public.trip_events to service_role;

create policy trips_select on public.trips
  for select to authenticated
  using (user_id = (select auth.uid()) or private.can_view_trip(id, (select auth.uid())));

create policy trip_watchers_select on public.trip_watchers
  for select to authenticated
  using (private.is_trip_owner(trip_id) or private.can_view_trip(trip_id, (select auth.uid())));

-- Le check-in sous contrainte n'est visible par AUCUN client.
create policy trip_events_select on public.trip_events
  for select to authenticated
  using (type <> 'checkin_duress' and private.can_view_trip(trip_id, (select auth.uid())));

-- -----------------------------------------------------------------------------
-- Photos de véhicule : bucket privé, chemin <user_id>/<trip_id>.jpg
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('vehicle-photos', 'vehicle-photos', false, 1048576, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public, file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

create or replace function private.trip_id_from_photo_path(p_name text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  return substring(p_name from '^[0-9a-f-]{36}/([0-9a-f-]{36})\.(jpg|jpeg|png|webp)$')::uuid;
exception when others then
  return null;
end;
$$;

create policy vehicle_photos_insert_own on storage.objects
  for insert to authenticated
  with check (bucket_id = 'vehicle-photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy vehicle_photos_update_own on storage.objects
  for update to authenticated
  using (bucket_id = 'vehicle-photos' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'vehicle-photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy vehicle_photos_delete_own on storage.objects
  for delete to authenticated
  using (bucket_id = 'vehicle-photos' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy vehicle_photos_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'vehicle-photos'
    and ((storage.foldername(name))[1] = (select auth.uid())::text
         or private.can_view_trip(private.trip_id_from_photo_path(name), (select auth.uid())))
  );

-- Suppression d'un trajet → photo en file de suppression.
create or replace function private.trips_after_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.vehicle_photo_path is not null then
    insert into private.storage_deletion_queue (bucket, path)
    values ('vehicle-photos', old.vehicle_photo_path) on conflict do nothing;
  end if;
  return old;
end;
$$;
create trigger trips_after_delete after delete on public.trips
  for each row execute function private.trips_after_delete();

-- -----------------------------------------------------------------------------
-- File d'envoi : réveil immédiat de `trip-watchdog` (pg_net, après COMMIT).
-- Sans secrets Vault (local), ne fait rien : pg_cron et les fonctions Edge
-- prennent le relais.
-- -----------------------------------------------------------------------------
create or replace function private.trip_events_wake()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from new_rows where dispatched_at is null) then
    perform private.invoke_edge_function('trip-watchdog', '{"dispatch": true}'::jsonb);
  end if;
  return null;
exception when others then
  raise warning 'trip_events_wake: %', sqlerrm;
  return null;
end;
$$;
create trigger trip_events_wake after insert on public.trip_events
  referencing new table as new_rows
  for each statement execute function private.trip_events_wake();

-- Événement interne (déjà « envoyé » si p_silent : rien à notifier).
create or replace function private.trip_event(
  p_trip public.trips,
  p_type public.trip_event_type,
  p_metadata jsonb default '{}'::jsonb,
  p_silent boolean default false
)
returns bigint
language sql
security definer
set search_path = ''
as $$
  insert into public.trip_events (trip_id, user_id, type, lat, lng, metadata, dispatched_at)
  values (p_trip.id, p_trip.user_id, p_type, p_trip.last_lat, p_trip.last_lng, coalesce(p_metadata, '{}'::jsonb),
          case when p_silent then now() end)
  returning id;
$$;

create or replace function private.trip_snapshot(p_trip public.trips)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_trip.id, 'status', p_trip.status, 'mode', p_trip.mode,
    'destination_label', p_trip.destination_label,
    'destination', jsonb_build_object('lat', p_trip.destination_lat, 'lng', p_trip.destination_lng),
    'expected_arrival_at', p_trip.expected_arrival_at, 'grace_minutes', p_trip.grace_minutes,
    'started_at', p_trip.started_at, 'ended_at', p_trip.ended_at,
    'vehicle_plate', p_trip.vehicle_plate, 'vehicle_note', p_trip.vehicle_note,
    'vehicle_photo_path', p_trip.vehicle_photo_path, 'extensions_count', p_trip.extensions_count
  );
$$;

-- -----------------------------------------------------------------------------
-- Position : push_location prend en compte le trajet actif
-- (points rattachés, diffusion sur `trip:<id>`, arrivée automatique).
-- -----------------------------------------------------------------------------
create or replace function public.push_location(
  p_lat double precision,
  p_lng double precision,
  p_accuracy_m real default null,
  p_recorded_at timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  active_sos uuid;
  tr public.trips;
  has_window boolean;
  rec_at timestamptz := least(coalesce(p_recorded_at, now()), now());
  pt extensions.geography := extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography;
begin
  if uid is null then
    raise exception 'Authentification requise' using errcode = '42501';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Coordonnées invalides' using errcode = '22023';
  end if;
  if rec_at < now() - interval '1 hour' then
    return;
  end if;

  has_window := private.has_active_location_window(uid);
  select * into tr from public.trips where user_id = uid and ended_at is null and status in ('active', 'escalated')
  order by started_at desc limit 1;
  if not has_window and tr.id is null then
    return;
  end if;

  select id into active_sos from public.sos_events where user_id = uid and status = 'active';

  insert into public.location_points (user_id, sos_event_id, trip_id, lat, lng, accuracy_m, recorded_at)
  values (uid, active_sos, tr.id, p_lat, p_lng, p_accuracy_m, rec_at);

  if active_sos is not null then
    update public.sos_events
       set last_location = pt, last_accuracy_m = p_accuracy_m, last_location_at = rec_at
     where id = active_sos;
  end if;

  if has_window then
    perform private.broadcast('location:' || uid, 'position', jsonb_build_object(
      'user_id', uid, 'lat', p_lat, 'lng', p_lng, 'accuracy_m', p_accuracy_m,
      'recorded_at', rec_at, 'sos_event_id', active_sos));
  end if;

  if tr.id is not null then
    update public.trips
       set last_lat = p_lat, last_lng = p_lng, last_accuracy_m = p_accuracy_m, last_location_at = rec_at
     where id = tr.id
     returning * into tr;
    perform private.broadcast('trip:' || tr.id, 'position', jsonb_build_object(
      'trip_id', tr.id, 'lat', p_lat, 'lng', p_lng, 'accuracy_m', p_accuracy_m, 'recorded_at', rec_at));

    -- Arrivée automatique (pas pendant une escalade).
    if tr.status = 'active'
       and extensions.st_dwithin(pt, tr.destination, (private.trip_config() ->> 'arrival_radius_m')::int) then
      update public.trips set status = 'arrived', ended_at = now(), checkin_round = 0 where id = tr.id
      returning * into tr;
      perform private.trip_event(tr, 'arrived', jsonb_build_object('auto', true));
      perform private.broadcast('trip:' || tr.id, 'status', jsonb_build_object('trip_id', tr.id, 'status', 'arrived'));
    end if;
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- RPC client
-- -----------------------------------------------------------------------------

-- « Le trafic est dense » : repousse l'heure d'arrivée (max 3 fois, 5 à 120 min).
create or replace function public.trip_extend(p_trip_id uuid, p_minutes int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  tr public.trips;
begin
  select * into tr from public.trips where id = p_trip_id and user_id = auth.uid() for update;
  if not found or tr.status <> 'active' then
    raise exception 'Aucun trajet en cours' using errcode = 'P0002';
  end if;
  if p_minutes is null or p_minutes not between 5 and 120 then
    raise exception 'Durée invalide (5 à 120 min)' using errcode = '22023';
  end if;
  if tr.extensions_count >= (private.trip_config() ->> 'max_extensions')::int then
    raise exception 'Vous avez déjà repoussé ce trajet % fois', tr.extensions_count using errcode = 'P0001';
  end if;
  update public.trips
     set expected_arrival_at = greatest(expected_arrival_at, now()) + make_interval(mins => p_minutes),
         extensions_count = extensions_count + 1,
         checkin_round = 0, checkin_requested_at = null, checkin_reason = null, late_notified_at = null
   where id = tr.id
   returning * into tr;
  perform private.trip_event(tr, 'extended', jsonb_build_object('minutes', p_minutes), true);
  perform private.broadcast('trip:' || tr.id, 'status',
    jsonb_build_object('trip_id', tr.id, 'status', tr.status, 'expected_arrival_at', tr.expected_arrival_at));
  return private.trip_snapshot(tr);
end;
$$;

-- Véhicule (plaque lue sur le téléphone, photo déjà téléversée).
create or replace function public.set_trip_vehicle(
  p_trip_id uuid,
  p_plate text default null,
  p_photo_path text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  tr public.trips;
  plate text := nullif(upper(regexp_replace(coalesce(p_plate, ''), '[^A-Za-z0-9]', '', 'g')), '');
begin
  select * into tr from public.trips where id = p_trip_id and user_id = auth.uid() for update;
  if not found or tr.ended_at is not null then
    raise exception 'Aucun trajet en cours' using errcode = 'P0002';
  end if;
  if p_photo_path is not null and p_photo_path !~ ('^' || auth.uid() || '/' || p_trip_id || '\.(jpg|jpeg|png|webp)$') then
    raise exception 'Chemin de photo invalide' using errcode = '22023';
  end if;
  if plate is not null and plate !~ '^[A-Z0-9]{2,12}$' then
    raise exception 'Plaque invalide' using errcode = '22023';
  end if;
  update public.trips
     set vehicle_plate = coalesce(plate, vehicle_plate),
         vehicle_photo_path = coalesce(p_photo_path, vehicle_photo_path),
         vehicle_note = coalesce(left(p_note, 200), vehicle_note)
   where id = tr.id
   returning * into tr;
  return private.trip_snapshot(tr);
end;
$$;

-- Batterie faible signalée par l'app : les proches sont prévenus UNE fois,
-- avec la dernière position, avant que le téléphone s'éteigne.
create or replace function public.trip_battery_low(
  p_trip_id uuid,
  p_level int,
  p_lat double precision default null,
  p_lng double precision default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  tr public.trips;
begin
  select * into tr from public.trips where id = p_trip_id and user_id = auth.uid() and ended_at is null for update;
  if not found then
    return;
  end if;
  if p_level is null or p_level not between 0 and 100 then
    raise exception 'Niveau de batterie invalide' using errcode = '22023';
  end if;
  update public.trips
     set last_battery = p_level,
         last_lat = coalesce(p_lat, last_lat), last_lng = coalesce(p_lng, last_lng),
         last_location_at = case when p_lat is not null then now() else last_location_at end
   where id = tr.id
   returning * into tr;
  if tr.battery_notified_at is null and p_level <= 15 then
    update public.trips set battery_notified_at = now() where id = tr.id;
    perform private.trip_event(tr, 'battery_low', jsonb_build_object('level', p_level));
  end if;
end;
$$;

-- Suivi d'un trajet par un proche (accès audité) ou par le voyageur.
create or replace function public.get_trip_live(p_trip_id uuid, p_trail_minutes int default 120)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  viewer uuid := auth.uid();
  tr public.trips;
  result jsonb;
begin
  if not private.can_view_trip(p_trip_id, viewer) then
    return null;
  end if;
  select * into tr from public.trips where id = p_trip_id;

  select private.trip_snapshot(tr) || jsonb_build_object(
    'traveler', (select jsonb_build_object('user_id', p.id, 'full_name', p.full_name, 'phone', p.phone,
                                           'avatar_url', p.avatar_url)
                 from public.profiles p where p.id = tr.user_id),
    'last_battery', tr.last_battery,
    'last_location_at', tr.last_location_at,
    'late_minutes', greatest(0, floor(extract(epoch from (now() - tr.expected_arrival_at)) / 60))::int,
    'trail', case when tr.ended_at is not null and tr.user_id <> viewer then '[]'::jsonb else coalesce((
      select jsonb_agg(jsonb_build_object('lat', lat, 'lng', lng, 'accuracy_m', accuracy_m, 'recorded_at', recorded_at)
                       order by recorded_at)
      from public.location_points
      where trip_id = tr.id
        and recorded_at > now() - make_interval(mins => least(greatest(coalesce(p_trail_minutes, 120), 1), 1440))
    ), '[]'::jsonb) end
  ) into result;

  if viewer <> tr.user_id then
    perform private.audit('trip.viewed', tr.user_id, 'trips', tr.id::text, jsonb_build_object('via', 'app'));
  end if;
  return result;
end;
$$;

-- Trajets en cours que je suis (côté proche).
create or replace function public.get_trips_i_watch()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'trip_id', t.id, 'status', t.status, 'mode', t.mode, 'destination_label', t.destination_label,
    'expected_arrival_at', t.expected_arrival_at, 'started_at', t.started_at,
    'traveler', jsonb_build_object('user_id', p.id, 'full_name', p.full_name, 'avatar_url', p.avatar_url))
    order by t.started_at desc), '[]'::jsonb)
  from public.trips t
  join public.profiles p on p.id = t.user_id
  where t.ended_at is null and t.status in ('active', 'escalated')
    and private.is_trip_watcher(t.id, auth.uid());
$$;

-- Signalements le long d'un itinéraire : [[lat, lng], …] (2 à 500 points).
create or replace function public.route_risks(
  p_route jsonb,
  p_since_minutes int default 720,
  p_buffer_m int default 300
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  line extensions.geography;
  wkt text;
begin
  if auth.uid() is null then
    raise exception 'Authentification requise' using errcode = '42501';
  end if;
  if jsonb_typeof(p_route) <> 'array' or jsonb_array_length(p_route) not between 2 and 500 then
    raise exception 'Itinéraire invalide (2 à 500 points)' using errcode = '22023';
  end if;
  begin
    select 'LINESTRING(' || string_agg((p ->> 1)::double precision || ' ' || (p ->> 0)::double precision, ',' order by i) || ')'
      into wkt
    from jsonb_array_elements(p_route) with ordinality as e(p, i);
    line := extensions.st_geogfromtext('SRID=4326;' || wkt);
  exception when others then
    raise exception 'Itinéraire invalide' using errcode = '22023';
  end;

  return (
    select jsonb_build_object(
      'count', count(*),
      'night', extract(hour from now() at time zone 'Africa/Dakar') >= 20
               or extract(hour from now() at time zone 'Africa/Dakar') < 6,
      'by_category', coalesce((select jsonb_object_agg(category, n) from (
          select r2.category, count(*) n from public.risk_reports r2
          where r2.expires_at > now()
            and r2.created_at > now() - make_interval(mins => least(greatest(coalesce(p_since_minutes, 720), 1), 10080))
            and extensions.st_dwithin(r2.location, line, least(greatest(coalesce(p_buffer_m, 300), 50), 2000))
          group by r2.category) c), '{}'::jsonb),
      'reports', coalesce(jsonb_agg(jsonb_build_object(
          'id', r.id, 'category', r.category,
          'lat', round(r.lat::numeric, 3), 'lng', round(r.lng::numeric, 3),
          'created_at', r.created_at) order by r.created_at desc), '[]'::jsonb)
    )
    from public.risk_reports r
    where r.expires_at > now()
      and r.created_at > now() - make_interval(mins => least(greatest(coalesce(p_since_minutes, 720), 1), 10080))
      and extensions.st_dwithin(r.location, line, least(greatest(coalesce(p_buffer_m, 300), 50), 2000))
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Fonctions de service (Edge Functions)
-- -----------------------------------------------------------------------------

-- Démarre un trajet (idempotent via client_key). p_input :
-- { mode, destination:{lat,lng,label}, origin?:{lat,lng,label}, expected_arrival_at,
--   grace_minutes?, checkin_first_minutes?, checkin_second_minutes?,
--   watcher_contact_ids?: uuid[] (défaut : tous les proches), vehicle_plate?, vehicle_note?,
--   route?: [[lat,lng],…], position?:{lat,lng,accuracy_m} }
create or replace function public.svc_trip_start(p_user_id uuid, p_client_key uuid, p_input jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  tr public.trips;
  created boolean := false;
  route_wkt text;
  plate text := nullif(upper(regexp_replace(coalesce(p_input ->> 'vehicle_plate', ''), '[^A-Za-z0-9]', '', 'g')), '');
begin
  perform pg_advisory_xact_lock(hashtextextended('trip:' || p_user_id::text, 0));

  select * into tr from public.trips where user_id = p_user_id and client_key = p_client_key;
  if not found then
    if exists (select 1 from public.trips where user_id = p_user_id and status = 'active') then
      return jsonb_build_object('error', 'trip_already_active',
        'trip_id', (select id from public.trips where user_id = p_user_id and status = 'active'));
    end if;

    if jsonb_typeof(p_input -> 'route') = 'array' and jsonb_array_length(p_input -> 'route') between 2 and 500 then
      select 'SRID=4326;LINESTRING(' || string_agg((p ->> 1)::double precision || ' ' || (p ->> 0)::double precision, ',' order by i) || ')'
        into route_wkt
      from jsonb_array_elements(p_input -> 'route') with ordinality as e(p, i);
    end if;

    insert into public.trips (
      user_id, client_key, mode,
      origin_label, origin_lat, origin_lng,
      destination_label, destination_lat, destination_lng, route,
      expected_arrival_at, grace_minutes, checkin_first_minutes, checkin_second_minutes,
      vehicle_plate, vehicle_note, last_lat, last_lng, last_accuracy_m, last_location_at
    ) values (
      p_user_id, p_client_key, (p_input ->> 'mode')::public.trip_mode,
      left(p_input -> 'origin' ->> 'label', 200), (p_input -> 'origin' ->> 'lat')::double precision,
      (p_input -> 'origin' ->> 'lng')::double precision,
      btrim(p_input -> 'destination' ->> 'label'), (p_input -> 'destination' ->> 'lat')::double precision,
      (p_input -> 'destination' ->> 'lng')::double precision,
      case when route_wkt is null then null else extensions.st_geogfromtext(route_wkt) end,
      (p_input ->> 'expected_arrival_at')::timestamptz,
      coalesce((p_input ->> 'grace_minutes')::smallint, 15),
      coalesce((p_input ->> 'checkin_first_minutes')::smallint, 3),
      coalesce((p_input ->> 'checkin_second_minutes')::smallint, 2),
      plate, left(p_input ->> 'vehicle_note', 200),
      (p_input -> 'position' ->> 'lat')::double precision, (p_input -> 'position' ->> 'lng')::double precision,
      (p_input -> 'position' ->> 'accuracy_m')::real,
      case when p_input -> 'position' ->> 'lat' is not null then now() end
    ) returning * into tr;
    created := true;

    insert into public.trip_watchers (trip_id, contact_id)
    select tr.id, tc.id from public.trusted_contacts tc
    where tc.owner_id = p_user_id
      and (jsonb_typeof(p_input -> 'watcher_contact_ids') is distinct from 'array'
           or tc.id::text in (select jsonb_array_elements_text(p_input -> 'watcher_contact_ids')));

    if tr.last_lat is not null then
      insert into public.location_points (user_id, trip_id, lat, lng, accuracy_m, recorded_at)
      values (p_user_id, tr.id, tr.last_lat, tr.last_lng, tr.last_accuracy_m, now());
    end if;

    perform private.trip_event(tr, 'started', '{}'::jsonb);
    perform private.broadcast_to_trip_watchers(tr, 'trip_started', private.trip_snapshot(tr));
  end if;

  return jsonb_build_object(
    'created', created,
    'trip', private.trip_snapshot(tr),
    'watchers', (select count(*) from public.trip_watchers where trip_id = tr.id)
  );
end;
$$;

create or replace function private.broadcast_to_trip_watchers(p_trip public.trips, p_event text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  c record;
begin
  for c in
    select distinct tc.contact_user_id from public.trip_watchers w
    join public.trusted_contacts tc on tc.id = w.contact_id
    where w.trip_id = p_trip.id and tc.contact_user_id is not null
  loop
    perform private.broadcast('inbox:' || c.contact_user_id, p_event,
      p_payload || jsonb_build_object('trip_id', p_trip.id, 'user_id', p_trip.user_id));
  end loop;
end;
$$;

-- Réponse au « Tout va bien ? ». p_result : 'ok' | 'duress'. Les deux mettent
-- le trajet dans EXACTEMENT le même état visible ; seul un événement caché
-- (checkin_duress, jamais lisible par un client) distingue la contrainte.
create or replace function public.svc_trip_checkin(p_user_id uuid, p_trip_id uuid, p_result text,
  p_lat double precision default null, p_lng double precision default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  tr public.trips;
begin
  select * into tr from public.trips
  where id = p_trip_id and user_id = p_user_id and ended_at is null and status = 'active'
  for update;
  if not found then
    return null;
  end if;
  update public.trips
     set checkin_round = 0, checkin_requested_at = null, checkin_reason = null,
         checkin_snooze_until = now() + make_interval(mins => (private.trip_config() ->> 'snooze_minutes')::int),
         last_lat = coalesce(p_lat, last_lat), last_lng = coalesce(p_lng, last_lng),
         last_location_at = case when p_lat is not null then now() else last_location_at end
   where id = tr.id
   returning * into tr;
  if p_result = 'duress' then
    perform private.trip_event(tr, 'checkin_duress', '{}'::jsonb, true);
  else
    perform private.trip_event(tr, 'checkin_ok', '{}'::jsonb, true);
  end if;
  return jsonb_build_object('ok', true, 'trip_id', tr.id, 'next_check_after', tr.checkin_snooze_until);
end;
$$;

create or replace function public.svc_trip_arrive(p_user_id uuid, p_trip_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  tr public.trips;
begin
  select * into tr from public.trips
  where id = p_trip_id and user_id = p_user_id and status = 'active' for update;
  if not found then
    return null;
  end if;
  update public.trips set status = 'arrived', ended_at = now(), checkin_round = 0 where id = tr.id
  returning * into tr;
  perform private.trip_event(tr, 'arrived', jsonb_build_object('auto', false));
  perform private.broadcast('trip:' || tr.id, 'status', jsonb_build_object('trip_id', tr.id, 'status', 'arrived'));
  return private.trip_snapshot(tr);
end;
$$;

-- Annulation : les proches ne sont prévenus que si le trajet a réellement
-- commencé (plus de 2 min).
create or replace function public.svc_trip_cancel(p_user_id uuid, p_trip_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  tr public.trips;
  notify boolean;
begin
  select * into tr from public.trips
  where id = p_trip_id and user_id = p_user_id and status = 'active' for update;
  if not found then
    return null;
  end if;
  notify := tr.started_at < now() - make_interval(mins => (private.trip_config() ->> 'cancel_notify_after_minutes')::int);
  update public.trips set status = 'cancelled', ended_at = now(), checkin_round = 0 where id = tr.id
  returning * into tr;
  perform private.trip_event(tr, 'cancelled', jsonb_build_object('notify', notify), not notify);
  perform private.broadcast('trip:' || tr.id, 'status', jsonb_build_object('trip_id', tr.id, 'status', 'cancelled'));
  return private.trip_snapshot(tr) || jsonb_build_object('watchers_notified', notify);
end;
$$;

-- Réclame les événements à envoyer (au plus une fois à la fois ; nouvel essai
-- si un envoi réclamé n'est pas confirmé sous 2 min). Renvoie tout le
-- contexte nécessaire aux envois.
create or replace function public.svc_trip_claim_events(p_trip_id uuid default null, p_limit int default 50)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ids bigint[];
begin
  with c as (
    select id from public.trip_events
    where dispatched_at is null
      and (dispatch_claimed_at is null or dispatch_claimed_at < now() - interval '2 minutes')
      and (p_trip_id is null or trip_id = p_trip_id)
      and created_at > now() - interval '6 hours'
    order by created_at
    limit least(greatest(p_limit, 1), 200)
    for update skip locked
  ), u as (
    update public.trip_events e set dispatch_claimed_at = clock_timestamp()
    from c where e.id = c.id
    returning e.id
  )
  select array_agg(id) into ids from u;

  if ids is null then
    return '[]'::jsonb;
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'event_id', e.id, 'type', e.type, 'metadata', e.metadata, 'created_at', e.created_at,
      'lat', e.lat, 'lng', e.lng,
      'trip', private.trip_snapshot(t) || jsonb_build_object(
        'user_id', t.user_id, 'last_lat', t.last_lat, 'last_lng', t.last_lng,
        'last_location_at', t.last_location_at, 'last_battery', t.last_battery,
        'checkin_round', t.checkin_round,
        'checkin_minutes', case t.checkin_round when 1 then t.checkin_first_minutes else t.checkin_second_minutes end),
      'traveler', (select jsonb_build_object('id', p.id, 'full_name', p.full_name, 'phone', p.phone)
                   from public.profiles p where p.id = t.user_id),
      'traveler_push_tokens', coalesce((select jsonb_agg(jsonb_build_object('token', pt.token, 'platform', pt.platform))
                                        from public.push_tokens pt where pt.user_id = t.user_id), '[]'::jsonb),
      'watchers', coalesce((
        select jsonb_agg(jsonb_build_object(
          'contact_id', tc.id, 'name', tc.name, 'phone', tc.phone, 'contact_user_id', tc.contact_user_id,
          'push_tokens', coalesce((select jsonb_agg(jsonb_build_object('token', pt.token, 'platform', pt.platform))
                                   from public.push_tokens pt where pt.user_id = tc.contact_user_id), '[]'::jsonb)))
        from public.trip_watchers w join public.trusted_contacts tc on tc.id = w.contact_id
        where w.trip_id = t.id), '[]'::jsonb)
    ) order by e.created_at)
    from public.trip_events e join public.trips t on t.id = e.trip_id
    where e.id = any (ids)
  ), '[]'::jsonb);
end;
$$;

-- Résultat des envois : [{event_id, ok, error?}]
create or replace function public.svc_trip_events_done(p_results jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.trip_events e
     set dispatched_at = case when (r ->> 'ok')::boolean then now() else null end,
         dispatch_claimed_at = case when (r ->> 'ok')::boolean then e.dispatch_claimed_at else null end,
         dispatch_error = left(r ->> 'error', 500)
    from jsonb_array_elements(p_results) r
   where e.id = (r ->> 'event_id')::bigint;
$$;

-- -----------------------------------------------------------------------------
-- Surveillance (pg_cron, chaque minute)
--   Anomalies : retard (heure prévue + marge), plus de position, arrêt
--   prolongé, écart à l'itinéraire. Escalade : « Tout va bien ? » (tour 1),
--   relance après N1 min (tour 2), SOS après N2 min sans réponse.
--   Les heures calmes ne s'appliquent jamais.
-- -----------------------------------------------------------------------------
create or replace function private.trip_anomaly(tr public.trips)
returns public.trip_event_type
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  cfg jsonb := private.trip_config();
  last_pt extensions.geography;
  spread double precision;
  n int;
begin
  if now() > tr.expected_arrival_at + make_interval(mins => tr.grace_minutes) then
    return 'late';
  end if;
  if tr.started_at < now() - make_interval(mins => (cfg ->> 'no_signal_minutes')::int)
     and coalesce(tr.last_location_at, tr.started_at) < now() - make_interval(mins => (cfg ->> 'no_signal_minutes')::int) then
    return 'no_signal';
  end if;
  if tr.last_lat is null then
    return null;
  end if;
  last_pt := extensions.st_setsrid(extensions.st_makepoint(tr.last_lng, tr.last_lat), 4326)::extensions.geography;

  -- Arrêt prolongé loin de la destination.
  if tr.started_at < now() - make_interval(mins => (cfg ->> 'stopped_minutes')::int)
     and not extensions.st_dwithin(last_pt, tr.destination, (cfg ->> 'stopped_ignore_near_dest_m')::int) then
    select count(*), max(extensions.st_distance(lp.location, last_pt)) into n, spread
    from public.location_points lp
    where lp.trip_id = tr.id
      and lp.recorded_at > now() - make_interval(mins => (cfg ->> 'stopped_minutes')::int);
    if n >= 3 and spread <= (cfg ->> 'stopped_radius_m')::int
       and exists (select 1 from public.location_points lp2 where lp2.trip_id = tr.id
                   and lp2.recorded_at <= now() - make_interval(mins => (cfg ->> 'stopped_minutes')::int)) then
      return 'stopped';
    end if;
  end if;

  if tr.route is not null and not extensions.st_dwithin(last_pt, tr.route, (cfg ->> 'deviation_m')::int) then
    return 'deviation';
  end if;
  return null;
end;
$$;

create or replace function private.trip_watchdog_tick()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  tr public.trips;
  anomaly public.trip_event_type;
  actions int := 0;
begin
  -- Trajets trop longs : expirés.
  update public.trips set status = 'expired', ended_at = now()
   where status = 'active'
     and started_at < now() - make_interval(hours => (private.trip_config() ->> 'max_trip_hours')::int);

  for tr in
    select * from public.trips t
    where t.status = 'active'
      -- Pendant un SOS (visible ou silencieux), le SOS a la main.
      and not exists (select 1 from public.sos_events e where e.user_id = t.user_id and e.status = 'active')
    for update skip locked
  loop
    if tr.checkin_round = 0 then
      if tr.checkin_snooze_until is not null and now() < tr.checkin_snooze_until then
        continue;
      end if;
      anomaly := private.trip_anomaly(tr);
      if anomaly is null then
        continue;
      end if;
      update public.trips
         set checkin_round = 1, checkin_requested_at = now(), checkin_reason = anomaly,
             late_notified_at = case when anomaly = 'late' then coalesce(late_notified_at, now()) else late_notified_at end
       where id = tr.id
       returning * into tr;
      -- Retard : les proches sont prévenus une fois.
      if anomaly = 'late' and tr.late_notified_at > now() - interval '5 seconds' then
        perform private.trip_event(tr, 'late', jsonb_build_object(
          'late_minutes', greatest(0, floor(extract(epoch from (now() - tr.expected_arrival_at)) / 60))::int));
      elsif anomaly <> 'late' then
        perform private.trip_event(tr, anomaly, '{}'::jsonb, true);
      end if;
      perform private.trip_event(tr, 'checkin_requested', jsonb_build_object('round', 1, 'reason', anomaly));
      actions := actions + 1;

    elsif tr.checkin_round = 1 and now() >= tr.checkin_requested_at + make_interval(mins => tr.checkin_first_minutes) then
      update public.trips set checkin_round = 2, checkin_requested_at = now() where id = tr.id
      returning * into tr;
      perform private.trip_event(tr, 'checkin_requested', jsonb_build_object('round', 2, 'reason', tr.checkin_reason));
      actions := actions + 1;

    elsif tr.checkin_round = 2 and now() >= tr.checkin_requested_at + make_interval(mins => tr.checkin_second_minutes) then
      -- Aucune réponse : ESCALADE EN SOS, sans aucune action du téléphone.
      update public.trips set status = 'escalated' where id = tr.id returning * into tr;
      perform private.trip_event(tr, 'escalated', jsonb_build_object('reason', tr.checkin_reason));
      perform private.broadcast('trip:' || tr.id, 'status', jsonb_build_object('trip_id', tr.id, 'status', 'escalated'));
      actions := actions + 1;
    end if;
  end loop;
  return actions;
end;
$$;

-- Pour les tests e2e et l'exploitation : un tour de surveillance à la demande.
create or replace function public.svc_trip_watchdog_tick()
returns int
language sql
security definer
set search_path = ''
as $$
  select private.trip_watchdog_tick();
$$;

-- Lien de suivi web d'un trajet (proche sans l'app) — jeton vérifié par la
-- fonction Edge. Plus aucune position une fois le trajet terminé.
create or replace function public.svc_trip_track(p_trip_id uuid, p_contact_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  tr public.trips;
begin
  select t.* into tr from public.trips t
  where t.id = p_trip_id
    and exists (select 1 from public.trip_watchers w where w.trip_id = t.id and w.contact_id = p_contact_id);
  if not found then
    return null;
  end if;
  insert into public.audit_log (actor_id, subject_user_id, action, target_table, target_id, metadata)
  values (null, tr.user_id, 'trip.viewed', 'trips', tr.id::text,
          jsonb_build_object('via', 'web_link', 'contact_id', p_contact_id));

  if tr.ended_at is not null then
    return jsonb_build_object('kind', 'trip', 'status', tr.status,
      'name', (select full_name from public.profiles where id = tr.user_id), 'ended_at', tr.ended_at);
  end if;
  return jsonb_build_object(
    'kind', 'trip', 'status', tr.status,
    'name', (select full_name from public.profiles where id = tr.user_id),
    'mode', tr.mode, 'destination_label', tr.destination_label,
    'destination', jsonb_build_object('lat', tr.destination_lat, 'lng', tr.destination_lng),
    'expected_arrival_at', tr.expected_arrival_at, 'started_at', tr.started_at,
    'vehicle_plate', tr.vehicle_plate, 'vehicle_note', tr.vehicle_note,
    'vehicle_photo_path', tr.vehicle_photo_path, 'last_battery', tr.last_battery,
    'trail', coalesce((
      select jsonb_agg(jsonb_build_object('lat', lat, 'lng', lng, 'accuracy_m', accuracy_m, 'recorded_at', recorded_at)
                       order by recorded_at)
      from (select lat, lng, accuracy_m, recorded_at from public.location_points
            where trip_id = tr.id order by recorded_at desc limit 300) s), '[]'::jsonb)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Liens avec le SOS
-- -----------------------------------------------------------------------------
-- Un SOS (non silencieux) pendant un trajet rattache le trajet au SOS. Un SOS
-- silencieux n'est JAMAIS rattaché : la victime pourrait le voir.
create or replace function private.sos_events_link_trip()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not new.silent then
    update public.trips set sos_event_id = new.id
     where user_id = new.user_id and ended_at is null and status in ('active', 'escalated') and sos_event_id is null;
  end if;
  return new;
end;
$$;
create trigger sos_events_link_trip after insert on public.sos_events
  for each row execute function private.sos_events_link_trip();

-- Clôture du SOS → fin d'un trajet escaladé.
create or replace function private.sos_events_close_trip()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.status = 'active' and new.status <> 'active' then
    update public.trips set ended_at = now()
     where sos_event_id = new.id and status = 'escalated' and ended_at is null;
  end if;
  return new;
end;
$$;
create trigger sos_events_close_trip after update of status on public.sos_events
  for each row execute function private.sos_events_close_trip();

-- Realtime : canal `trip:<id>` pour le voyageur et les watchers d'un trajet en cours.
create or replace function private.can_receive_topic(p_topic text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  viewer uuid := auth.uid();
  kind text := split_part(p_topic, ':', 1);
  subject uuid;
begin
  if viewer is null then
    return false;
  end if;
  begin
    subject := split_part(p_topic, ':', 2)::uuid;
  exception when others then
    return false;
  end;
  if kind = 'inbox' then
    return subject = viewer;
  elsif kind = 'location' then
    return private.can_view_location(subject, viewer);
  elsif kind = 'home' then
    return exists (select 1 from public.home_members where home_id = subject and user_id = viewer);
  elsif kind = 'trip' then
    return private.can_view_trip(subject, viewer);
  end if;
  return false;
end;
$$;

-- -----------------------------------------------------------------------------
-- Rétention : trajets et traces 30 jours (90 jours si rattachés à un SOS),
-- positions hors trajet/SOS 7 jours.
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
  -- Trajets (photo supprimée par trigger ; watchers et événements en cascade).
  delete from public.trips
   where ended_at is not null and sos_event_id is null and started_at < now() - interval '30 days';
  delete from public.trips
   where ended_at is not null and sos_event_id is not null and started_at < now() - interval '90 days';
  delete from public.risk_reports where expires_at < now() - interval '1 day';
  delete from public.device_events where received_at < now() - interval '30 days';
  delete from public.audit_log where created_at < now() - interval '365 days';
end;
$$;

-- -----------------------------------------------------------------------------
-- Export : données de transport ajoutées à export_my_data()
-- -----------------------------------------------------------------------------
alter function public.export_my_data() rename to export_my_data_core;
revoke execute on function public.export_my_data_core() from public, anon, authenticated;

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
                    from public.trip_events e where e.user_id = uid and e.type <> 'checkin_duress')
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- pg_cron : surveillance chaque minute + rattrapage des envois.
-- -----------------------------------------------------------------------------
select cron.schedule('jammtech-trip-watchdog', '* * * * *', $$
  select private.trip_watchdog_tick() where exists (select 1 from public.trips where status = 'active');
  select private.invoke_edge_function('trip-watchdog', '{"dispatch": true}'::jsonb)
   where exists (select 1 from public.trip_events
                 where dispatched_at is null and created_at > now() - interval '6 hours'
                   and (dispatch_claimed_at is null or dispatch_claimed_at < now() - interval '2 minutes'));
$$);

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
  private.trip_id_from_photo_path(text)
to authenticated;

grant execute on function
  public.push_location(double precision, double precision, real, timestamptz),
  public.trip_extend(uuid, int),
  public.set_trip_vehicle(uuid, text, text, text),
  public.trip_battery_low(uuid, int, double precision, double precision),
  public.get_trip_live(uuid, int),
  public.get_trips_i_watch(),
  public.route_risks(jsonb, int, int),
  public.export_my_data()
to authenticated;

revoke execute on function
  public.svc_trip_start(uuid, uuid, jsonb),
  public.svc_trip_checkin(uuid, uuid, text, double precision, double precision),
  public.svc_trip_arrive(uuid, uuid),
  public.svc_trip_cancel(uuid, uuid),
  public.svc_trip_claim_events(uuid, int),
  public.svc_trip_events_done(jsonb),
  public.svc_trip_watchdog_tick(),
  public.svc_trip_track(uuid, uuid),
  public.export_my_data_core()
from authenticated;
grant execute on function
  public.svc_trip_start(uuid, uuid, jsonb),
  public.svc_trip_checkin(uuid, uuid, text, double precision, double precision),
  public.svc_trip_arrive(uuid, uuid),
  public.svc_trip_cancel(uuid, uuid),
  public.svc_trip_claim_events(uuid, int),
  public.svc_trip_events_done(jsonb),
  public.svc_trip_watchdog_tick(),
  public.svc_trip_track(uuid, uuid)
to service_role;
