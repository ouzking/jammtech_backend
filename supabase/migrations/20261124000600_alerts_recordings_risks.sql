-- =============================================================================
-- Incréments 6 et 7 — Alertes, enregistrements vidéo, zones à risque
-- =============================================================================

-- -----------------------------------------------------------------------------
-- recordings (créée avant les alertes, qui y font référence)
-- -----------------------------------------------------------------------------
create table public.recordings (
  id uuid primary key default gen_random_uuid(),
  home_id uuid not null references public.homes (id) on delete cascade,
  device_id uuid references public.devices (id) on delete set null,
  title text not null default 'Enregistrement' check (length(title) between 1 and 120),
  storage_path text not null unique check (length(storage_path) <= 512),
  thumbnail_path text check (thumbnail_path is null or length(thumbnail_path) <= 512),
  duration_seconds int not null default 0 check (duration_seconds between 0 and 86400),
  motion_detected boolean not null default false,
  uploaded boolean not null default false,
  started_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days',
  created_at timestamptz not null default now()
);
comment on column public.recordings.expires_at is
  'Conservation 30 jours. Purge automatique (ligne + fichiers) par pg_cron → Edge Function purge-expired.';
create index recordings_home_idx on public.recordings (home_id, started_at desc);
create index recordings_device_idx on public.recordings (device_id, started_at desc);
create index recordings_expires_idx on public.recordings (expires_at);

-- File de suppression des fichiers Storage : la suppression directe dans
-- storage.objects est interdite, elle passe par l'API Storage (Edge Function).
create table private.storage_deletion_queue (
  id bigint generated always as identity primary key,
  bucket text not null,
  path text not null,
  attempts int not null default 0,
  last_error text,
  created_at timestamptz not null default now(),
  unique (bucket, path)
);
grant all on private.storage_deletion_queue to service_role;

create or replace function private.recordings_after_delete()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.storage_deletion_queue (bucket, path)
  values ('recordings', old.storage_path) on conflict do nothing;
  if old.thumbnail_path is not null then
    insert into private.storage_deletion_queue (bucket, path)
    values ('recordings', old.thumbnail_path) on conflict do nothing;
  end if;
  return old;
end;
$$;
create trigger recordings_after_delete after delete on public.recordings
  for each row execute function private.recordings_after_delete();

alter table public.recordings enable row level security;
revoke all on public.recordings from anon, authenticated;
grant select, delete on public.recordings to authenticated;
grant all on public.recordings to service_role;
create policy recordings_select_member on public.recordings
  for select to authenticated using (private.is_home_member(home_id));
create policy recordings_delete_owner on public.recordings
  for delete to authenticated using (private.is_home_owner(home_id));

-- -----------------------------------------------------------------------------
-- security_alerts
-- -----------------------------------------------------------------------------
create table public.security_alerts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete cascade,
  home_id uuid references public.homes (id) on delete cascade,
  category public.alert_category not null default 'system',
  title text not null check (length(title) between 1 and 120),
  description text not null default '' check (length(description) <= 1000),
  severity public.alert_severity not null default 'info',
  location_label text check (location_label is null or length(location_label) <= 120),
  location extensions.geography(Point, 4326),
  device_id uuid references public.devices (id) on delete set null,
  recording_id uuid references public.recordings (id) on delete set null,
  dedupe_key text,
  resolved_at timestamptz,
  resolved_by uuid references auth.users (id) on delete set null,
  notified_at timestamptz,
  created_at timestamptz not null default now(),
  check (user_id is not null or home_id is not null)
);
comment on column public.security_alerts.notified_at is
  'Rempli une fois les notifications traitées par send-notification (balayage pg_cron pour les retardataires).';
create index security_alerts_user_idx on public.security_alerts (user_id, created_at desc) where user_id is not null;
create index security_alerts_home_idx on public.security_alerts (home_id, created_at desc) where home_id is not null;
create index security_alerts_unresolved_idx on public.security_alerts (home_id) where resolved_at is null;
create index security_alerts_pending_notify_idx on public.security_alerts (created_at) where notified_at is null;
-- Évite les doublons (ex. « caméra hors ligne » répétée).
create unique index security_alerts_dedupe_idx on public.security_alerts (dedupe_key)
  where dedupe_key is not null and resolved_at is null;

alter table public.security_alerts enable row level security;
revoke all on public.security_alerts from anon, authenticated;
grant select on public.security_alerts to authenticated;
grant all on public.security_alerts to service_role;

create policy security_alerts_select on public.security_alerts
  for select to authenticated
  using (user_id = (select auth.uid()) or (home_id is not null and private.is_home_member(home_id)));

-- Marquer comme traitée / rouvrir / tout marquer comme traité.
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
  if not found or not (a.user_id = auth.uid() or (a.home_id is not null and private.is_home_member(a.home_id))) then
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
grant execute on function public.resolve_alert(uuid, boolean) to authenticated;

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
          or a.home_id in (select home_id from public.home_members where user_id = auth.uid()));
  get diagnostics n = row_count;
  return n;
end;
$$;
grant execute on function public.resolve_all_alerts() to authenticated;

-- Création d'une alerte par le système (fonctions Edge, tâches pg_cron).
create or replace function private.create_alert(
  p_user_id uuid,
  p_home_id uuid,
  p_category public.alert_category,
  p_severity public.alert_severity,
  p_title text,
  p_description text,
  p_location_label text default null,
  p_device_id uuid default null,
  p_recording_id uuid default null,
  p_dedupe_key text default null,
  p_location extensions.geography default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_id uuid;
begin
  insert into public.security_alerts (user_id, home_id, category, severity, title, description, location_label,
                                      device_id, recording_id, dedupe_key, location)
  values (p_user_id, p_home_id, p_category, p_severity, p_title, coalesce(p_description, ''), p_location_label,
          p_device_id, p_recording_id, p_dedupe_key, p_location)
  on conflict (dedupe_key) where dedupe_key is not null and resolved_at is null do nothing
  returning id into new_id;
  if new_id is not null and p_home_id is not null then
    perform private.broadcast('home:' || p_home_id, 'alert', jsonb_build_object(
      'id', new_id, 'severity', p_severity, 'title', p_title, 'category', p_category));
  end if;
  return new_id;
end;
$$;

create or replace function public.svc_create_alert(
  p_user_id uuid,
  p_home_id uuid,
  p_category public.alert_category,
  p_severity public.alert_severity,
  p_title text,
  p_description text,
  p_location_label text default null,
  p_device_id uuid default null,
  p_recording_id uuid default null,
  p_dedupe_key text default null
)
returns uuid
language sql
security definer
set search_path = ''
as $$
  select private.create_alert(p_user_id, p_home_id, p_category, p_severity, p_title, p_description,
                              p_location_label, p_device_id, p_recording_id, p_dedupe_key, null);
$$;
revoke execute on function public.svc_create_alert(uuid, uuid, public.alert_category, public.alert_severity,
  text, text, text, uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.svc_create_alert(uuid, uuid, public.alert_category, public.alert_severity,
  text, text, text, uuid, uuid, text) to service_role;

-- Destinataires d'une alerte : l'utilisateur ou tous les membres de la maison,
-- avec préférences, tokens et téléphone. Service uniquement.
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

create or replace function public.svc_mark_alert_notified(p_alert_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.security_alerts set notified_at = now() where id = p_alert_id and notified_at is null;
$$;

create or replace function public.svc_pending_alerts(p_limit int default 50)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.security_alerts
  where notified_at is null and created_at > now() - interval '1 hour'
  order by created_at
  limit least(greatest(p_limit, 1), 200);
$$;

revoke execute on function public.svc_alert_recipients(uuid), public.svc_mark_alert_notified(uuid),
  public.svc_pending_alerts(int) from public, anon, authenticated;
grant execute on function public.svc_alert_recipients(uuid), public.svc_mark_alert_notified(uuid),
  public.svc_pending_alerts(int) to service_role;

-- -----------------------------------------------------------------------------
-- Enregistrements : fonctions de service (ingestion + purge)
-- -----------------------------------------------------------------------------
create or replace function public.svc_expired_recordings(p_limit int default 200)
returns table (id uuid, storage_path text, thumbnail_path text)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.storage_path, r.thumbnail_path from public.recordings r
  where r.expires_at <= now()
  order by r.expires_at
  limit least(greatest(p_limit, 1), 1000);
$$;

create or replace function public.svc_storage_deletion_batch(p_limit int default 200)
returns table (id bigint, bucket text, path text)
language sql
security definer
set search_path = ''
as $$
  select q.id, q.bucket, q.path from private.storage_deletion_queue q
  where q.attempts < 10
  order by q.created_at
  limit least(greatest(p_limit, 1), 1000);
$$;

create or replace function public.svc_storage_deletion_done(p_done bigint[], p_failed bigint[], p_error text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from private.storage_deletion_queue where id = any (coalesce(p_done, '{}'));
  update private.storage_deletion_queue
     set attempts = attempts + 1, last_error = left(p_error, 500)
   where id = any (coalesce(p_failed, '{}'));
end;
$$;

revoke execute on function public.svc_expired_recordings(int), public.svc_storage_deletion_batch(int),
  public.svc_storage_deletion_done(bigint[], bigint[], text) from public, anon, authenticated;
grant execute on function public.svc_expired_recordings(int), public.svc_storage_deletion_batch(int),
  public.svc_storage_deletion_done(bigint[], bigint[], text) to service_role;

-- -----------------------------------------------------------------------------
-- risk_reports (zones à risque signalées par les utilisateurs)
-- -----------------------------------------------------------------------------
create table public.risk_reports (
  id uuid primary key default gen_random_uuid(),
  reported_by uuid references auth.users (id) on delete cascade,
  category public.risk_category not null,
  description text check (description is null or length(description) <= 500),
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  location extensions.geography(Point, 4326)
    generated always as (extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography) stored,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '24 hours',
  check (expires_at > created_at and expires_at <= created_at + interval '7 days')
);
create index risk_reports_location_idx on public.risk_reports using gist (location);
create index risk_reports_created_idx on public.risk_reports (created_at desc);

-- Anti-abus : 5 signalements par heure et par utilisateur.
create or replace function private.risk_reports_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select count(*) from public.risk_reports
      where reported_by = new.reported_by and created_at > now() - interval '1 hour') >= 5 then
    raise exception 'Trop de signalements. Réessayez plus tard.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;
create trigger risk_reports_rate_limit before insert on public.risk_reports
  for each row execute function private.risk_reports_rate_limit();

alter table public.risk_reports enable row level security;
revoke all on public.risk_reports from anon, authenticated;
grant select, delete on public.risk_reports to authenticated;
grant insert (reported_by, category, description, lat, lng) on public.risk_reports to authenticated;
grant all on public.risk_reports to service_role;

-- L'auteur voit / supprime ses signalements. Les autres utilisateurs passent
-- par `nearby_risks()` qui n'expose ni l'auteur ni la position exacte.
create policy risk_reports_select_own on public.risk_reports
  for select to authenticated using (reported_by = (select auth.uid()));
create policy risk_reports_insert_own on public.risk_reports
  for insert to authenticated with check (reported_by = (select auth.uid()));
create policy risk_reports_delete_own on public.risk_reports
  for delete to authenticated using (reported_by = (select auth.uid()));

-- « Incidents à moins de 500 m depuis 1 h ». Positions arrondies (~100 m)
-- pour ne pas révéler l'emplacement exact d'un signalement.
create or replace function public.nearby_risks(
  p_lat double precision,
  p_lng double precision,
  p_radius_m int default 500,
  p_since_minutes int default 60
)
returns table (
  id uuid,
  category public.risk_category,
  description text,
  lat double precision,
  lng double precision,
  distance_m int,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.category, r.description,
         round(r.lat::numeric, 3)::double precision,
         round(r.lng::numeric, 3)::double precision,
         round(extensions.st_distance(r.location,
           extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography))::int,
         r.created_at
  from public.risk_reports r
  where auth.uid() is not null
    and r.expires_at > now()
    and r.created_at > now() - make_interval(mins => least(greatest(coalesce(p_since_minutes, 60), 1), 1440))
    and extensions.st_dwithin(r.location,
          extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography,
          least(greatest(coalesce(p_radius_m, 500), 50), 5000))
  order by r.created_at desc
  limit 100;
$$;
grant execute on function public.nearby_risks(double precision, double precision, int, int) to authenticated;

-- Après un signalement : alerte « Zone à risque » (warning) pour les
-- utilisateurs dont la dernière position (< 30 min) est à moins de 500 m et
-- qui ont au moins 2 incidents autour d'eux depuis 1 h. Une alerte par
-- utilisateur et par heure au maximum.
create or replace function private.risk_reports_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  u record;
begin
  for u in
    select distinct on (lp.user_id) lp.user_id
    from public.location_points lp
    where lp.recorded_at > now() - interval '30 minutes'
      and lp.user_id <> coalesce(new.reported_by, '00000000-0000-0000-0000-000000000000'::uuid)
      and extensions.st_dwithin(lp.location, new.location, 500)
    order by lp.user_id, lp.recorded_at desc
  loop
    if (select count(*) from public.risk_reports r
        where r.created_at > now() - interval '1 hour' and r.expires_at > now()
          and extensions.st_dwithin(r.location, new.location, 500)) >= 2 then
      perform private.create_alert(
        u.user_id, null, 'zone', 'warning', 'Zone à risque signalée',
        'Plusieurs signalements d''incidents ont été remontés à moins de 500 m de votre position au cours de la dernière heure.',
        null, null, null,
        'zone:' || u.user_id || ':' || to_char(date_trunc('hour', now()), 'YYYYMMDDHH24'),
        null);
    end if;
  end loop;
  return null;
end;
$$;
create trigger risk_reports_after_insert after insert on public.risk_reports
  for each row execute function private.risk_reports_after_insert();
