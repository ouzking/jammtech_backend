-- =============================================================================
-- Incréments 3 et 4 — SOS et position
-- =============================================================================
-- Modèle :
--   * location_shares  : fenêtres pendant lesquelles les proches peuvent voir
--                        la position (partage manuel ou SOS).
--   * location_points  : points envoyés par l'app via `push_location()`.
--                        Le point n'est enregistré QUE si une fenêtre est active
--                        (minimisation des données).
--   * sos_events       : un SOS ; un seul SOS actif par utilisateur.
--   * sos_notifications: journal de chaque envoi (push / SMS) vers un proche.
-- Diffusion temps réel (Realtime Broadcast, canaux privés) :
--   * `location:<user_id>` : positions, lisible par les proches uniquement
--                            pendant un partage ou un SOS actif.
--   * `inbox:<user_id>`    : événements adressés à un utilisateur
--                            (SOS démarré / clos chez une personne protégée).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- sos_events
-- -----------------------------------------------------------------------------
create table public.sos_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  client_key uuid not null,
  status public.sos_status not null default 'active',
  trigger public.sos_trigger not null default 'button',
  silent boolean not null default false,
  started_at timestamptz not null default now(),
  resolved_at timestamptz,
  last_location extensions.geography(Point, 4326),
  last_accuracy_m real,
  last_location_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, client_key),
  check ((status = 'active') = (resolved_at is null))
);
comment on column public.sos_events.client_key is
  'Clé d''idempotence fournie par l''app : un nouvel essai réseau avec la même clé ne renvoie aucune notification.';
-- Un seul SOS actif par utilisateur.
create unique index sos_events_one_active_idx on public.sos_events (user_id) where status = 'active';
create index sos_events_user_idx on public.sos_events (user_id, started_at desc);

-- -----------------------------------------------------------------------------
-- location_shares
-- -----------------------------------------------------------------------------
create table public.location_shares (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  sos_event_id uuid references public.sos_events (id) on delete cascade,
  started_at timestamptz not null default now(),
  expires_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  check (ended_at is null or ended_at >= started_at)
);
create index location_shares_active_idx on public.location_shares (user_id) where ended_at is null;
create unique index location_shares_one_manual_active_idx on public.location_shares (user_id)
  where ended_at is null and sos_event_id is null;

-- -----------------------------------------------------------------------------
-- location_points
-- -----------------------------------------------------------------------------
create table public.location_points (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  sos_event_id uuid references public.sos_events (id) on delete set null,
  lat double precision not null check (lat between -90 and 90),
  lng double precision not null check (lng between -180 and 180),
  location extensions.geography(Point, 4326)
    generated always as (extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography) stored,
  accuracy_m real check (accuracy_m is null or accuracy_m >= 0),
  recorded_at timestamptz not null,
  created_at timestamptz not null default now()
);
comment on table public.location_points is
  'Données sensibles. Purge : 7 jours hors SOS, 90 jours pour les points rattachés à un SOS.';
create index location_points_user_time_idx on public.location_points (user_id, recorded_at desc);
create index location_points_sos_idx on public.location_points (sos_event_id) where sos_event_id is not null;
create index location_points_created_idx on public.location_points (created_at);

-- -----------------------------------------------------------------------------
-- sos_notifications
-- -----------------------------------------------------------------------------
create table public.sos_notifications (
  id uuid primary key default gen_random_uuid(),
  sos_event_id uuid not null references public.sos_events (id) on delete cascade,
  contact_id uuid references public.trusted_contacts (id) on delete set null,
  kind text not null default 'alert' check (kind in ('alert', 'resolved')),
  channel public.notification_channel not null,
  status public.notification_status not null default 'queued',
  provider text,
  provider_message_id text,
  error text check (error is null or length(error) <= 500),
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  delivered_at timestamptz
);
create index sos_notifications_event_idx on public.sos_notifications (sos_event_id);
create index sos_notifications_provider_msg_idx on public.sos_notifications (provider, provider_message_id)
  where provider_message_id is not null;
create index sos_notifications_queued_idx on public.sos_notifications (created_at) where status = 'queued';

-- -----------------------------------------------------------------------------
-- Aides de visibilité
-- -----------------------------------------------------------------------------

-- Fenêtre de partage active (manuelle ou SOS) pour `p_user`.
create or replace function private.has_active_location_window(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.location_shares
    where user_id = p_user
      and ended_at is null
      and (expires_at is null or expires_at > now())
  );
$$;
grant execute on function private.has_active_location_window(uuid) to authenticated;

-- Un proche ne voit la position QUE pendant un partage actif ou un SOS actif.
create or replace function private.can_view_location(p_owner uuid, p_viewer uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_viewer is not null
     and p_owner <> p_viewer
     and private.is_trusted_contact_of(p_owner, p_viewer)
     and private.has_active_location_window(p_owner);
$$;
grant execute on function private.can_view_location(uuid, uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.sos_events enable row level security;
alter table public.location_shares enable row level security;
alter table public.location_points enable row level security;
alter table public.sos_notifications enable row level security;

revoke all on public.sos_events, public.location_shares, public.location_points, public.sos_notifications
  from anon, authenticated;
grant select on public.sos_events, public.location_shares, public.location_points, public.sos_notifications
  to authenticated;
grant all on public.sos_events, public.location_shares, public.location_points, public.sos_notifications
  to service_role;

-- SOS : le propriétaire voit ses SOS, SAUF les SOS silencieux (code de
-- contrainte) afin qu'aucune trace n'apparaisse sur son appareil.
create policy sos_events_select_owner on public.sos_events
  for select to authenticated
  using (user_id = (select auth.uid()) and not silent);
-- Les proches voient les SOS actifs (y compris silencieux) des personnes
-- qu'ils protègent, et perdent l'accès dès la clôture.
create policy sos_events_select_contact on public.sos_events
  for select to authenticated
  using (status = 'active' and private.is_trusted_contact_of(user_id, (select auth.uid())));

create policy location_shares_select_owner on public.location_shares
  for select to authenticated
  using (
    user_id = (select auth.uid())
    and (sos_event_id is null
         or not exists (select 1 from public.sos_events e where e.id = sos_event_id and e.silent))
  );

-- Points : le propriétaire voit son historique hors SOS silencieux. Les
-- proches passent par `get_live_location()` (accès audité).
create policy location_points_select_owner on public.location_points
  for select to authenticated
  using (
    user_id = (select auth.uid())
    and (sos_event_id is null
         or not exists (select 1 from public.sos_events e where e.id = sos_event_id and e.silent))
  );

create policy sos_notifications_select_owner on public.sos_notifications
  for select to authenticated
  using (exists (
    select 1 from public.sos_events e
    where e.id = sos_event_id and e.user_id = (select auth.uid()) and not e.silent
  ));

-- -----------------------------------------------------------------------------
-- Realtime : autorisation des canaux privés
-- -----------------------------------------------------------------------------
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
  end if;
  return false;
end;
$$;
grant execute on function private.can_receive_topic(text) to authenticated;

-- `realtime.messages` est créée par le service Realtime de Supabase.
create policy jammtech_receive_private_topics on realtime.messages
  for select to authenticated
  using (realtime.messages.extension = 'broadcast' and private.can_receive_topic((select realtime.topic())));

-- Diffusion fiable : une erreur Realtime ne doit jamais faire échouer un SOS.
create or replace function private.broadcast(p_topic text, p_event text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform realtime.send(p_payload, p_event, p_topic, true);
exception when others then
  raise warning 'broadcast % failed: %', p_event, sqlerrm;
end;
$$;

create or replace function private.broadcast_to_contacts(p_owner uuid, p_event text, p_payload jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  c record;
begin
  for c in
    select distinct contact_user_id from public.trusted_contacts
    where owner_id = p_owner and contact_user_id is not null
  loop
    perform private.broadcast('inbox:' || c.contact_user_id, p_event, p_payload);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Position : RPC client
-- -----------------------------------------------------------------------------

-- Envoie un point de position. Ne fait rien (et ne révèle rien) si aucune
-- fenêtre de partage n'est active : l'app peut l'appeler sans condition.
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
  rec_at timestamptz := least(coalesce(p_recorded_at, now()), now());
begin
  if uid is null then
    raise exception 'Authentification requise' using errcode = '42501';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'Coordonnées invalides' using errcode = '22023';
  end if;
  if rec_at < now() - interval '1 hour' then
    return; -- point trop ancien, ignoré
  end if;
  if not private.has_active_location_window(uid) then
    return;
  end if;

  select id into active_sos from public.sos_events where user_id = uid and status = 'active';

  insert into public.location_points (user_id, sos_event_id, lat, lng, accuracy_m, recorded_at)
  values (uid, active_sos, p_lat, p_lng, p_accuracy_m, rec_at);

  if active_sos is not null then
    update public.sos_events
       set last_location = extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography,
           last_accuracy_m = p_accuracy_m,
           last_location_at = rec_at
     where id = active_sos;
  end if;

  perform private.broadcast('location:' || uid, 'position', jsonb_build_object(
    'user_id', uid, 'lat', p_lat, 'lng', p_lng, 'accuracy_m', p_accuracy_m,
    'recorded_at', rec_at, 'sos_event_id', active_sos
  ));
end;
$$;
grant execute on function public.push_location(double precision, double precision, real, timestamptz) to authenticated;

-- Démarre un partage manuel (durée par défaut 8 h, maximum 24 h).
create or replace function public.start_location_share(p_duration_minutes int default 480)
returns public.location_shares
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  share public.location_shares;
begin
  if uid is null then
    raise exception 'Authentification requise' using errcode = '42501';
  end if;
  if p_duration_minutes is null or p_duration_minutes not between 5 and 1440 then
    raise exception 'Durée de partage invalide (5 min à 24 h)' using errcode = '22023';
  end if;
  update public.location_shares set ended_at = now()
   where user_id = uid and sos_event_id is null and ended_at is null;
  insert into public.location_shares (user_id, expires_at)
  values (uid, now() + make_interval(mins => p_duration_minutes))
  returning * into share;
  perform private.broadcast_to_contacts(uid, 'location_share_started',
    jsonb_build_object('user_id', uid, 'share_id', share.id, 'expires_at', share.expires_at));
  return share;
end;
$$;
grant execute on function public.start_location_share(int) to authenticated;

create or replace function public.stop_location_share()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
begin
  update public.location_shares set ended_at = now()
   where user_id = uid and sos_event_id is null and ended_at is null;
  perform private.broadcast_to_contacts(uid, 'location_share_stopped', jsonb_build_object('user_id', uid));
end;
$$;
grant execute on function public.stop_location_share() to authenticated;

-- Position en direct d'une personne protégée (accès audité). Renvoie NULL si
-- aucun partage / SOS actif : l'accès se ferme dès la clôture.
create or replace function public.get_live_location(p_user_id uuid, p_trail_minutes int default 30)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  viewer uuid := auth.uid();
  ev public.sos_events;
  result jsonb;
begin
  if not private.can_view_location(p_user_id, viewer) then
    return null;
  end if;
  select * into ev from public.sos_events where user_id = p_user_id and status = 'active';

  select jsonb_build_object(
    'user_id', p_user_id,
    'sos', case when ev.id is null then null else jsonb_build_object(
      'id', ev.id, 'started_at', ev.started_at, 'silent', ev.silent, 'trigger', ev.trigger) end,
    'trail', coalesce((
      select jsonb_agg(jsonb_build_object('lat', lat, 'lng', lng, 'accuracy_m', accuracy_m, 'recorded_at', recorded_at)
                       order by recorded_at)
      from public.location_points
      where user_id = p_user_id
        and recorded_at > now() - make_interval(mins => least(greatest(coalesce(p_trail_minutes, 30), 1), 240))
        and (ev.id is null or recorded_at >= ev.started_at - interval '1 minute')
    ), '[]'::jsonb)
  ) into result;

  perform private.audit('location.viewed', p_user_id, 'location_points', null,
    jsonb_build_object('via', 'app', 'sos_event_id', ev.id));
  return result;
end;
$$;
grant execute on function public.get_live_location(uuid, int) to authenticated;

-- -----------------------------------------------------------------------------
-- SOS : fonctions de service (appelées par les Edge Functions)
-- -----------------------------------------------------------------------------

-- Nombre maximal de SOS déclenchant des SMS sur 24 h (anti-abus / coûts).
-- Au-delà, les push partent toujours, les SMS sont journalisés en échec.
create or replace function private.sos_sms_daily_cap()
returns int language sql immutable as $$ select 10 $$;

-- Liste des destinataires d'un SOS avec leurs tokens push et notifications.
create or replace function private.sos_recipients(p_event_id uuid, p_notification_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(r order by r ->> 'priority'), '[]'::jsonb)
  from (
    select jsonb_build_object(
      'contact_id', tc.id,
      'name', tc.name,
      'phone', tc.phone,
      'priority', tc.priority,
      'contact_user_id', tc.contact_user_id,
      'push_tokens', coalesce((
        select jsonb_agg(jsonb_build_object('token', pt.token, 'platform', pt.platform))
        from public.push_tokens pt where pt.user_id = tc.contact_user_id
      ), '[]'::jsonb),
      'notifications', (
        select jsonb_agg(jsonb_build_object('id', n.id, 'channel', n.channel, 'status', n.status, 'error', n.error))
        from public.sos_notifications n
        where n.sos_event_id = p_event_id and n.contact_id = tc.id and n.id = any (p_notification_ids)
      )
    ) as r
    from public.trusted_contacts tc
    where exists (
      select 1 from public.sos_notifications n
      where n.sos_event_id = p_event_id and n.contact_id = tc.id and n.id = any (p_notification_ids)
    )
  ) s;
$$;

-- Démarre un SOS (idempotent) et prépare les notifications en UN aller-retour.
-- Renvoie :
--   { created, event, owner, recipients[], owner_push_tokens[] }
-- Si l'appel est rejoué (même client_key, ou SOS déjà actif), aucune nouvelle
-- notification n'est créée ; seules les notifications restées `queued` depuis
-- plus de 10 s sont renvoyées pour un nouvel essai.
create or replace function public.svc_sos_start(
  p_user_id uuid,
  p_client_key uuid,
  p_trigger public.sos_trigger default 'button',
  p_silent boolean default false,
  p_lat double precision default null,
  p_lng double precision default null,
  p_accuracy_m real default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ev public.sos_events;
  created boolean := false;
  sms_allowed boolean;
  share_location boolean;
  notif_ids uuid[];
  c record;
begin
  perform pg_advisory_xact_lock(hashtextextended('sos:' || p_user_id::text, 0));

  select * into ev from public.sos_events where user_id = p_user_id and client_key = p_client_key;
  if not found then
    select * into ev from public.sos_events where user_id = p_user_id and status = 'active';
  end if;

  if not found then
    insert into public.sos_events (user_id, client_key, trigger, silent)
    values (p_user_id, p_client_key, p_trigger, coalesce(p_silent, false))
    returning * into ev;
    created := true;

    -- Réglage « partage automatique en SOS ». Un SOS silencieux partage
    -- toujours la position : c'est la seule information utile aux proches.
    if ev.silent or coalesce((select auto_share_on_sos from public.user_settings where user_id = p_user_id), true) then
      insert into public.location_shares (user_id, sos_event_id) values (p_user_id, ev.id);
    end if;

    sms_allowed := (
      select count(*) from public.sos_events
      where user_id = p_user_id and started_at > now() - interval '24 hours'
    ) <= private.sos_sms_daily_cap();

    for c in
      select tc.id, tc.contact_user_id,
             exists (select 1 from public.push_tokens pt where pt.user_id = tc.contact_user_id) as has_push
      from public.trusted_contacts tc
      where tc.owner_id = p_user_id
      order by tc.priority, tc.created_at
    loop
      if c.has_push then
        insert into public.sos_notifications (sos_event_id, contact_id, channel)
        values (ev.id, c.id, 'push');
      end if;
      -- SMS de secours systématique (la data mobile n'est pas garantie).
      if sms_allowed then
        insert into public.sos_notifications (sos_event_id, contact_id, channel)
        values (ev.id, c.id, 'sms');
      else
        insert into public.sos_notifications (sos_event_id, contact_id, channel, status, error)
        values (ev.id, c.id, 'sms', 'failed', 'rate_limited');
      end if;
    end loop;

    perform private.broadcast_to_contacts(p_user_id, 'sos_started', jsonb_build_object(
      'user_id', p_user_id, 'sos_event_id', ev.id, 'silent', ev.silent, 'started_at', ev.started_at));
  end if;

  share_location := exists (select 1 from public.location_shares where sos_event_id = ev.id and ended_at is null);

  -- Position initiale transmise avec le SOS.
  if share_location and p_lat is not null and p_lng is not null
     and p_lat between -90 and 90 and p_lng between -180 and 180 then
    insert into public.location_points (user_id, sos_event_id, lat, lng, accuracy_m, recorded_at)
    values (p_user_id, ev.id, p_lat, p_lng, p_accuracy_m, now());
    update public.sos_events
       set last_location = extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography,
           last_accuracy_m = p_accuracy_m,
           last_location_at = now()
     where id = ev.id
     returning * into ev;
    perform private.broadcast('location:' || p_user_id, 'position', jsonb_build_object(
      'user_id', p_user_id, 'lat', p_lat, 'lng', p_lng, 'accuracy_m', p_accuracy_m,
      'recorded_at', now(), 'sos_event_id', ev.id));
  end if;

  select array_agg(id) into notif_ids
  from public.sos_notifications
  where sos_event_id = ev.id
    and kind = 'alert'
    and status = 'queued'
    and (created or created_at < now() - interval '10 seconds');

  return jsonb_build_object(
    'created', created,
    'location_shared', share_location,
    'event', jsonb_build_object(
      'id', ev.id, 'status', ev.status, 'trigger', ev.trigger, 'silent', ev.silent,
      'started_at', ev.started_at, 'client_key', ev.client_key),
    'owner', (select jsonb_build_object('id', p.id, 'full_name', p.full_name, 'phone', p.phone)
              from public.profiles p where p.id = p_user_id),
    'recipients', private.sos_recipients(ev.id, coalesce(notif_ids, '{}')),
    'owner_push_tokens', coalesce((
      select jsonb_agg(jsonb_build_object('token', token, 'platform', platform))
      from public.push_tokens where user_id = p_user_id), '[]'::jsonb)
  );
end;
$$;

-- Met à jour en lot le statut des notifications après envoi.
-- p_updates : [{ id, status, provider?, provider_message_id?, error? }]
create or replace function public.svc_update_sos_notifications(p_updates jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.sos_notifications n
     set status = (u ->> 'status')::public.notification_status,
         provider = coalesce(u ->> 'provider', n.provider),
         provider_message_id = coalesce(u ->> 'provider_message_id', n.provider_message_id),
         error = left(u ->> 'error', 500),
         sent_at = case when u ->> 'status' in ('sent', 'delivered') then coalesce(n.sent_at, now()) else n.sent_at end,
         delivered_at = case when u ->> 'status' = 'delivered' then now() else n.delivered_at end
    from jsonb_array_elements(p_updates) u
   where n.id = (u ->> 'id')::uuid;
$$;

-- Accusé de livraison SMS (webhook fournisseur).
create or replace function public.svc_mark_sms_status(p_provider text, p_message_id text, p_status text, p_error text default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.sos_notifications
     set status = case
           when p_status = 'delivered' then 'delivered'::public.notification_status
           when p_status = 'failed' then 'failed'::public.notification_status
           else status end,
         delivered_at = case when p_status = 'delivered' then now() else delivered_at end,
         error = coalesce(left(p_error, 500), error)
   where provider = p_provider and provider_message_id = p_message_id;
$$;

-- Clôt un ou plusieurs SOS actifs. Les SOS silencieux ne sont clos que si
-- p_include_silent est vrai (code de désarmement vérifié par la fonction Edge).
-- Renvoie { events[], recipients[] } : les proches à prévenir (ceux qui ont
-- reçu l'alerte), avec une notification `resolved` préparée par canal.
create or replace function public.svc_sos_resolve(
  p_user_id uuid,
  p_event_id uuid default null,
  p_outcome public.sos_status default 'resolved',
  p_include_silent boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  closed uuid[];
  notif_ids uuid[] := '{}';
  ids uuid[];
  ev uuid;
  recipients jsonb := '[]'::jsonb;
begin
  if p_outcome not in ('resolved', 'cancelled') then
    raise exception 'Issue invalide' using errcode = '22023';
  end if;

  with upd as (
    update public.sos_events
       set status = p_outcome, resolved_at = now()
     where user_id = p_user_id
       and status = 'active'
       and (p_event_id is null or id = p_event_id)
       and (not silent or p_include_silent)
    returning id
  )
  select array_agg(id) into closed from upd;

  if closed is null then
    return jsonb_build_object('events', '[]'::jsonb, 'recipients', '[]'::jsonb);
  end if;

  update public.location_shares set ended_at = now()
   where sos_event_id = any (closed) and ended_at is null;

  foreach ev in array closed loop
    with ins as (
      insert into public.sos_notifications (sos_event_id, contact_id, kind, channel)
      select distinct ev, n.contact_id, 'resolved'::text, n.channel
      from public.sos_notifications n
      where n.sos_event_id = ev and n.kind = 'alert' and n.contact_id is not null
        and n.status in ('sent', 'delivered')
      returning id
    )
    select array_agg(id) into ids from ins;
    notif_ids := notif_ids || coalesce(ids, '{}');
    recipients := recipients || private.sos_recipients(ev, coalesce(ids, '{}'));
  end loop;

  perform private.broadcast_to_contacts(p_user_id, 'sos_closed', jsonb_build_object(
    'user_id', p_user_id, 'sos_event_ids', to_jsonb(closed), 'outcome', p_outcome));

  return jsonb_build_object(
    'events', to_jsonb(closed),
    'outcome', p_outcome,
    'owner', (select jsonb_build_object('id', p.id, 'full_name', p.full_name, 'phone', p.phone)
              from public.profiles p where p.id = p_user_id),
    'recipients', recipients
  );
end;
$$;

-- Données publiques minimales d'un SOS pour la page de suivi web (proche sans
-- l'app). L'authenticité du lien (jeton HMAC) est vérifiée par la fonction Edge
-- `sos-track` ; ici on vérifie que le contact appartient bien au SOS. Aucune
-- position n'est renvoyée une fois le SOS clos.
create or replace function public.svc_sos_track(p_event_id uuid, p_contact_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  ev public.sos_events;
  owner_name text;
begin
  select e.* into ev from public.sos_events e
  where e.id = p_event_id
    and exists (select 1 from public.trusted_contacts tc where tc.id = p_contact_id and tc.owner_id = e.user_id);
  if not found then
    return null;
  end if;
  select full_name into owner_name from public.profiles where id = ev.user_id;

  insert into public.audit_log (actor_id, subject_user_id, action, target_table, target_id, metadata)
  values (null, ev.user_id, 'location.viewed', 'sos_events', ev.id::text,
          jsonb_build_object('via', 'web_link', 'contact_id', p_contact_id));

  if ev.status <> 'active' then
    return jsonb_build_object('status', ev.status, 'name', owner_name, 'resolved_at', ev.resolved_at);
  end if;

  return jsonb_build_object(
    'status', ev.status,
    'name', owner_name,
    'silent', ev.silent,
    'started_at', ev.started_at,
    'trail', coalesce((
      select jsonb_agg(jsonb_build_object('lat', lat, 'lng', lng, 'accuracy_m', accuracy_m, 'recorded_at', recorded_at)
                       order by recorded_at)
      from (
        select lat, lng, accuracy_m, recorded_at from public.location_points
        where user_id = ev.user_id and recorded_at >= ev.started_at - interval '1 minute'
        order by recorded_at desc limit 200
      ) t
    ), '[]'::jsonb)
  );
end;
$$;

revoke execute on function public.svc_sos_start(uuid, uuid, public.sos_trigger, boolean, double precision, double precision, real),
  public.svc_update_sos_notifications(jsonb),
  public.svc_mark_sms_status(text, text, text, text),
  public.svc_sos_resolve(uuid, uuid, public.sos_status, boolean),
  public.svc_sos_track(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.svc_sos_start(uuid, uuid, public.sos_trigger, boolean, double precision, double precision, real),
  public.svc_update_sos_notifications(jsonb),
  public.svc_mark_sms_status(text, text, text, text),
  public.svc_sos_resolve(uuid, uuid, public.sos_status, boolean),
  public.svc_sos_track(uuid, uuid)
  to service_role;
