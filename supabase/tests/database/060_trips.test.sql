-- Transport, phase 1 : trajets sécurisés (accès, surveillance serveur,
-- contrainte, arrivée automatique, rétention).
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

-- ---------------------------------------------------------------- helpers ---
create function pg_temp.new_user(p_phone text, p_name text default 'Test', p_confirmed boolean default true)
returns uuid language plpgsql as $$
declare uid uuid := gen_random_uuid();
begin
  insert into auth.users (id, aud, role, phone, phone_confirmed_at, raw_user_meta_data, created_at, updated_at)
  values (uid, 'authenticated', 'authenticated', ltrim(p_phone, '+'), case when p_confirmed then now() end,
          jsonb_build_object('full_name', p_name), now(), now());
  return uid;
end $$;
create function pg_temp.as_user(p_id uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', jsonb_build_object('sub', p_id, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_id::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
-- Un tour de surveillance avec l'heure du trajet décalée dans le passé.
create function pg_temp.trip(p_id uuid) returns public.trips language sql as $$
  select * from public.trips where id = p_id
$$;
grant execute on all functions in schema pg_temp to authenticated;
-- ----------------------------------------------------------------------------

select plan(54);

create temp table ids as
select pg_temp.new_user('+221776660001', 'Voyageuse') as t,
       pg_temp.new_user('+221776660002', 'Watcher') as w,
       pg_temp.new_user('+221776660003', 'Proche non choisi') as n,
       pg_temp.new_user('+221776660004', 'Inconnu') as s,
       gen_random_uuid() as k1;
grant select on ids to public;

insert into trusted_contacts (owner_id, name, phone, priority) values
  ((select t from ids), 'Watcher', '+221776660002', 1),
  ((select t from ids), 'Proche non choisi', '+221776660003', 2),
  ((select t from ids), 'Sans app', '+221766660005', 3);
insert into push_tokens (user_id, token, platform) values ((select w from ids), 'fcm-watcher-0000000001', 'android');
insert into security_codes (user_id, disarm_code_hash, duress_code_hash)
values ((select t from ids), crypt('1234', gen_salt('bf', 4)), crypt('9999', gen_salt('bf', 4)));

create temp table c as
select (select id from trusted_contacts where phone = '+221776660002') as cw,
       (select id from trusted_contacts where phone = '+221766660005') as cx;
grant select on c to public;

-- Démarrage (service)
set local role service_role;
create temp table r1 as select svc_trip_start((select t from ids), (select k1 from ids), jsonb_build_object(
  'mode', 'taxi',
  'destination', jsonb_build_object('lat', 14.7167, 'lng', -17.4677, 'label', 'Maison, Mermoz'),
  'expected_arrival_at', now() + interval '30 minutes',
  'watcher_contact_ids', jsonb_build_array((select cw from c), (select cx from c)),
  'vehicle_plate', 'dk-1234-ab',
  'route', jsonb_build_array(jsonb_build_array(14.6928, -17.4467), jsonb_build_array(14.7167, -17.4677)),
  'position', jsonb_build_object('lat', 14.6928, 'lng', -17.4467, 'accuracy_m', 10))) as j;
create temp table r2 as select svc_trip_start((select t from ids), (select k1 from ids), '{}'::jsonb) as j;
create temp table r3 as select svc_trip_start((select t from ids), gen_random_uuid(), jsonb_build_object(
  'mode', 'walk', 'destination', jsonb_build_object('lat', 14.7, 'lng', -17.4, 'label', 'X'),
  'expected_arrival_at', now() + interval '10 minutes')) as j;
reset role;
grant select on r1 to public;

create temp table tr as select (j -> 'trip' ->> 'id')::uuid as id from r1;
grant select on tr to public;

select is((select (j ->> 'created')::boolean from r1), true, 'trajet créé');
select is((select (j ->> 'watchers')::int from r1), 2, '2 proches choisis suivent le trajet');
select is((select j -> 'trip' ->> 'vehicle_plate' from r1), 'DK1234AB', 'plaque normalisée');
select is((select (j ->> 'created')::boolean from r2), false, 'rejeu réseau : pas de doublon');
select is((select j ->> 'error' from r3), 'trip_already_active', 'un seul trajet actif par utilisateur');
select is((select count(*)::int from trip_events where trip_id = (select id from tr) and type = 'started'
           and dispatched_at is null), 1, 'notification de départ en file');
select is((select count(*)::int from location_points where trip_id = (select id from tr)), 1, 'position de départ enregistrée');
select ok(exists (select 1 from realtime.messages where topic = 'inbox:' || (select w from ids) and event = 'trip_started'),
          'le watcher inscrit est prévenu en temps réel');

-- Accès
select pg_temp.as_user((select w from ids));
select is((select count(*)::int from trips), 1, 'le watcher voit le trajet');
select is((select vehicle_plate from trips), 'DK1234AB', 'le watcher voit la plaque');
select isnt(get_trip_live((select id from tr)), null, 'le watcher suit le trajet en direct');
select ok(private.can_receive_topic('trip:' || (select id from tr)), 'le watcher peut rejoindre le canal du trajet');
select is(jsonb_array_length(get_trips_i_watch()), 1, 'trajets suivis listés');
reset role;
select ok(exists (select 1 from audit_log where action = 'trip.viewed' and actor_id = (select w from ids)),
          'consultation du trajet auditée');

select pg_temp.as_user((select n from ids));
select is((select count(*)::int from trips), 0, 'un proche NON choisi ne voit pas le trajet');
select is(get_trip_live((select id from tr)), null, 'un proche non choisi ne suit pas le trajet');
select ok(not private.can_receive_topic('trip:' || (select id from tr)), 'un proche non choisi ne rejoint pas le canal');
reset role;
select pg_temp.as_user((select s from ids));
select is((select count(*)::int from trips), 0, 'un inconnu ne voit rien');
select is((select count(*)::int from trip_events), 0, 'un inconnu ne voit aucun événement');
reset role;

select pg_temp.as_user((select t from ids));
select throws_ok($$ update trips set expected_arrival_at = now() + interval '5 hours' $$, '42501', null,
                 'le voyageur ne modifie pas le trajet directement');
select lives_ok($$ select push_location(14.70, -17.45, 8) $$, 'envoi de position pendant le trajet');
reset role;
select is((select count(*)::int from location_points where trip_id = (select id from tr)), 2, 'point rattaché au trajet');
select ok(exists (select 1 from realtime.messages where topic = 'trip:' || (select id from tr) and event = 'position'),
          'position diffusée sur le canal du trajet');

-- Photo du véhicule
insert into storage.objects (bucket_id, name) select 'vehicle-photos', (select t from ids) || '/' || id || '.jpg' from tr;
select pg_temp.as_user((select w from ids));
select is((select count(*)::int from storage.objects where bucket_id = 'vehicle-photos'), 1, 'le watcher voit la photo du véhicule');
reset role;
select pg_temp.as_user((select n from ids));
select is((select count(*)::int from storage.objects where bucket_id = 'vehicle-photos'), 0, 'un proche non choisi ne la voit pas');
reset role;

-- Surveillance : téléphone muet, retard au-delà de la marge
update trips set started_at = now() - interval '2 hours', expected_arrival_at = now() - interval '20 minutes',
                 last_location_at = now() - interval '1 hour'
 where id = (select id from tr);
select is(private.trip_watchdog_tick() >= 1, true, 'surveillance : anomalie détectée');
select is((pg_temp.trip((select id from tr))).checkin_round, 1::smallint, '« Tout va bien ? » envoyé (tour 1)');
select is((pg_temp.trip((select id from tr))).checkin_reason, 'late'::trip_event_type, 'motif : retard');
select is((select count(*)::int from trip_events where trip_id = (select id from tr) and type = 'late'), 1,
          'les proches sont prévenus du retard');
select private.trip_watchdog_tick();
select is((pg_temp.trip((select id from tr))).checkin_round, 1::smallint, 'pas de relance avant le délai');

-- Réponse normale
set local role service_role;
select is(svc_trip_checkin((select t from ids), (select id from tr), 'ok') ->> 'ok', 'true', 'check-in normal');
reset role;
select is((pg_temp.trip((select id from tr))).checkin_round, 0::smallint, 'surveillance remise à zéro');
select private.trip_watchdog_tick();
select is((pg_temp.trip((select id from tr))).checkin_round, 0::smallint, 'pas de nouvelle question pendant la pause');

-- Réponse sous contrainte : même état visible, événement caché
update trips set checkin_snooze_until = now() - interval '1 second' where id = (select id from tr);
select private.trip_watchdog_tick();
set local role service_role;
create temp table ck as select svc_trip_checkin((select t from ids), (select id from tr), 'duress') as j;
reset role;
select is((select j - 'next_check_after' from ck), jsonb_build_object('ok', true, 'trip_id', (select id from tr)),
          'contrainte : même réponse qu''un check-in normal');
select is((pg_temp.trip((select id from tr))).checkin_round, 0::smallint, 'contrainte : même état visible du trajet');
select is((select count(*)::int from trip_events where type = 'checkin_duress'), 1, 'contrainte journalisée côté serveur');
select pg_temp.as_user((select t from ids));
select is((select count(*)::int from trip_events where type = 'checkin_duress'), 0, 'contrainte invisible pour la voyageuse');
reset role;
select pg_temp.as_user((select w from ids));
select is((select count(*)::int from trip_events where type = 'checkin_duress'), 0, 'contrainte invisible pour le watcher');
reset role;

-- Escalade : aucune réponse → SOS, sans action du téléphone
update trips set checkin_snooze_until = now() - interval '1 second' where id = (select id from tr);
select private.trip_watchdog_tick();
update trips set checkin_requested_at = now() - interval '4 minutes' where id = (select id from tr);
select private.trip_watchdog_tick();
select is((pg_temp.trip((select id from tr))).checkin_round, 2::smallint, 'relance après 3 min (tour 2)');
update trips set checkin_requested_at = now() - interval '3 minutes' where id = (select id from tr);
select private.trip_watchdog_tick();
select is((pg_temp.trip((select id from tr))).status, 'escalated'::trip_status, 'sans réponse : escalade en SOS');
select is((select count(*)::int from trip_events where trip_id = (select id from tr) and type = 'escalated'
           and dispatched_at is null), 1, 'escalade en file d''envoi');

-- File d'envoi
set local role service_role;
create temp table claim1 as select svc_trip_claim_events((select id from tr), 50) as j;
create temp table claim2 as select svc_trip_claim_events((select id from tr), 50) as j;
reset role;
select ok((select jsonb_array_length(j) from claim1) >= 3, 'événements réclamés avec leur contexte');
select is((select jsonb_array_length(j) from claim2), 0, 'un événement n''est réclamé qu''une fois à la fois');
select is((select jsonb_array_length(j -> 0 -> 'watchers') from claim1), 2, 'contexte : les 2 watchers');

-- SOS créé par l'escalade : rattaché au trajet, puis clôture
set local role service_role;
create temp table sos as select svc_sos_start((select t from ids), (select id from tr), 'trip_watchdog') as j;
reset role;
select is((pg_temp.trip((select id from tr))).sos_event_id, (select (j -> 'event' ->> 'id')::uuid from sos),
          'le SOS est rattaché au trajet');
set local role service_role;
select svc_sos_resolve((select t from ids), null, 'resolved');
reset role;
select isnt((pg_temp.trip((select id from tr))).ended_at, null, 'clôture du SOS : trajet terminé');
select pg_temp.as_user((select w from ids));
select is((select count(*)::int from trips), 0, 'le watcher perd l''accès quand le trajet est terminé');
reset role;

-- Arrivée automatique à moins de 150 m
set local role service_role;
create temp table r4 as select svc_trip_start((select t from ids), gen_random_uuid(), jsonb_build_object(
  'mode', 'moto', 'destination', jsonb_build_object('lat', 14.7167, 'lng', -17.4677, 'label', 'Maison'),
  'expected_arrival_at', now() + interval '20 minutes')) as j;
reset role;
select pg_temp.as_user((select t from ids));
select push_location(14.7170, -17.4680, 5);
reset role;
select is((select status from trips where id = (select (j -> 'trip' ->> 'id')::uuid from r4)), 'arrived'::trip_status,
          'arrivée automatique à moins de 150 m');
select is((select count(*)::int from trip_events where trip_id = (select (j -> 'trip' ->> 'id')::uuid from r4)
           and type = 'arrived' and dispatched_at is null), 1, 'proches prévenus de l''arrivée');

-- Repousser l'heure d'arrivée : 3 fois maximum ; annulation immédiate sans prévenir
set local role service_role;
create temp table r5 as select svc_trip_start((select t from ids), gen_random_uuid(), jsonb_build_object(
  'mode', 'public', 'destination', jsonb_build_object('lat', 14.8, 'lng', -17.3, 'label', 'Travail'),
  'expected_arrival_at', now() + interval '40 minutes')) as j;
reset role;
grant select on r5 to public;
select pg_temp.as_user((select t from ids));
select trip_extend((select (j -> 'trip' ->> 'id')::uuid from r5), 10);
select trip_extend((select (j -> 'trip' ->> 'id')::uuid from r5), 10);
select trip_extend((select (j -> 'trip' ->> 'id')::uuid from r5), 10);
select throws_ok($$ select trip_extend((select (j -> 'trip' ->> 'id')::uuid from r5), 10) $$, 'P0001', null,
                 'au plus 3 reports');
reset role;
set local role service_role;
select svc_trip_cancel((select t from ids), (select (j -> 'trip' ->> 'id')::uuid from r5));
reset role;
select is((select dispatched_at is not null from trip_events
           where trip_id = (select (j -> 'trip' ->> 'id')::uuid from r5) and type = 'cancelled'), true,
          'annulation dans les 2 premières minutes : proches non dérangés');

-- Zones à risque le long d'un itinéraire
insert into risk_reports (reported_by, category, lat, lng) values ((select s from ids), 'theft', 16.0300, -16.4900);
select pg_temp.as_user((select t from ids));
select is((route_risks('[[16.0250, -16.4950], [16.0350, -16.4850]]'::jsonb) ->> 'count')::int, 1,
          'signalement détecté le long de l''itinéraire');
reset role;

-- Rétention : trajets de plus de 30 jours supprimés, photo comprise
update trips set started_at = now() - interval '31 days', expected_arrival_at = now() - interval '30 days',
                 ended_at = now() - interval '30 days', sos_event_id = null,
                 vehicle_photo_path = (select t from ids) || '/' || id || '.jpg'
 where id = (select (j -> 'trip' ->> 'id')::uuid from r4);
select private.purge_retention();
select is((select count(*)::int from trips where id = (select (j -> 'trip' ->> 'id')::uuid from r4)), 0,
          'trajet de plus de 30 jours purgé');
select ok(exists (select 1 from private.storage_deletion_queue where bucket = 'vehicle-photos'
                  and path like '%' || (select (j -> 'trip' ->> 'id') from r4) || '%'), 'photo du véhicule mise en file de suppression');

select * from finish();
rollback;
