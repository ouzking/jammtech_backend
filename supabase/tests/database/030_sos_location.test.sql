-- Incréments 3 et 4 : SOS, partage de position, accès des proches.
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
grant execute on all functions in schema pg_temp to authenticated;
-- ----------------------------------------------------------------------------

select plan(41);

create temp table ids as
select pg_temp.new_user('+221773330001', 'Victime') as v,
       pg_temp.new_user('+221773330002', 'Proche App') as c1,
       pg_temp.new_user('+221773330003', 'Etranger') as stranger,
       gen_random_uuid() as key1,
       gen_random_uuid() as key2;
grant select on ids to public;

insert into trusted_contacts (owner_id, name, phone, priority) values
  ((select v from ids), 'Proche App', '+221773330002', 1),
  ((select v from ids), 'Proche SMS 1', '+221763330004', 2),
  ((select v from ids), 'Proche SMS 2', '+221783330005', 3);
insert into push_tokens (user_id, token, platform) values ((select c1 from ids), 'fcm-token-proche-00001', 'android');

-- Hors SOS / partage : aucune position enregistrée, rien de visible
select pg_temp.as_user((select v from ids));
select lives_ok($$ select push_location(14.69, -17.44, 10) $$, 'push_location sans fenêtre active : sans erreur');
reset role;
select is((select count(*)::int from location_points where user_id = (select v from ids)), 0,
          'aucun point stocké hors partage (minimisation)');

select pg_temp.as_user((select c1 from ids));
select is(get_live_location((select v from ids)), null, 'le proche ne voit rien hors partage / SOS');
reset role;

-- Les clients ne peuvent pas démarrer un SOS directement
select pg_temp.as_user((select v from ids));
select throws_ok($$ select svc_sos_start(auth.uid(), gen_random_uuid()) $$, '42501', null,
                 'svc_sos_start réservé au service');
select throws_ok($$ insert into sos_events (user_id, client_key) values (auth.uid(), gen_random_uuid()) $$, '42501', null,
                 'insertion directe de SOS interdite');
reset role;

-- Démarrage SOS (service)
set local role service_role;
create temp table r1 as select svc_sos_start((select v from ids), (select key1 from ids), 'button', false, 14.6928, -17.4467, 8) as j;
reset role;
select is((select (j ->> 'created')::boolean from r1), true, 'SOS créé');
select is((select jsonb_array_length(j -> 'recipients') from r1), 3, '3 proches à notifier');
select is((select count(*)::int from sos_notifications where channel = 'sms'
           and sos_event_id = (select (j -> 'event' ->> 'id')::uuid from r1)), 3, 'SMS de secours pour chaque proche');
select is((select count(*)::int from sos_notifications where channel = 'push'
           and sos_event_id = (select (j -> 'event' ->> 'id')::uuid from r1)), 1, 'push pour le proche ayant l''app');
select is((select count(*)::int from location_points where user_id = (select v from ids)), 1, 'position initiale enregistrée');
select ok((select count(*) from realtime.messages where topic = 'inbox:' || (select c1 from ids) and event = 'sos_started') = 1,
          'proche inscrit prévenu en temps réel');

-- Idempotence : même clé → rien de nouveau
set local role service_role;
create temp table r2 as select svc_sos_start((select v from ids), (select key1 from ids)) as j;
create temp table r3 as select svc_sos_start((select v from ids), (select key2 from ids)) as j;
reset role;
select is((select (j ->> 'created')::boolean from r2), false, 'rejeu avec la même clé : pas de nouveau SOS');
select is((select j -> 'event' ->> 'id' from r2), (select j -> 'event' ->> 'id' from r1), 'même événement renvoyé');
select is((select jsonb_array_length(j -> 'recipients') from r2), 0, 'aucune notification renvoyée au rejeu immédiat');
select is((select (j ->> 'created')::boolean from r3), false, 'second SOS pendant un SOS actif : réutilise l''actif');
select is((select count(*)::int from sos_notifications), 4, 'aucune notification dupliquée');

-- Mise à jour des statuts
set local role service_role;
select svc_update_sos_notifications((
  select jsonb_agg(jsonb_build_object('id', id, 'status', 'sent', 'provider', 'test', 'provider_message_id', 'm-' || id))
  from sos_notifications));
select svc_mark_sms_status('test', 'm-' || (select id from sos_notifications where channel = 'sms' limit 1), 'delivered');
reset role;
select is((select count(*)::int from sos_notifications where status in ('sent', 'delivered')), 4, 'statuts journalisés');
select is((select count(*)::int from sos_notifications where status = 'delivered'), 1, 'accusé de livraison enregistré');

-- Pendant le SOS
select pg_temp.as_user((select v from ids));
select push_location(14.6930, -17.4470, 6);
select is((select count(*)::int from sos_events), 1, 'la victime voit son SOS (non silencieux)');
select is((select count(*)::int from sos_notifications), 4, 'la victime voit le journal des envois');
reset role;
select is((select count(*)::int from location_points where user_id = (select v from ids)), 2, 'positions enregistrées pendant le SOS');
select ok((select count(*) from realtime.messages where topic = 'location:' || (select v from ids) and event = 'position') >= 2,
          'positions diffusées sur le canal privé');

select pg_temp.as_user((select c1 from ids));
select is((select count(*)::int from sos_events), 1, 'le proche voit le SOS actif');
select is(jsonb_array_length(get_live_location((select v from ids)) -> 'trail'), 2, 'le proche suit la position en direct');
select is((select count(*)::int from location_points), 0, 'le proche ne lit pas la table des points directement');
select ok(private.can_receive_topic('location:' || (select v from ids)), 'le proche peut rejoindre le canal position');
reset role;
select ok(exists (select 1 from audit_log where action = 'location.viewed' and subject_user_id = (select v from ids)
                  and actor_id = (select c1 from ids)), 'accès à la position audité');

select pg_temp.as_user((select stranger from ids));
select is((select count(*)::int from sos_events), 0, 'un tiers ne voit pas le SOS');
select is(get_live_location((select v from ids)), null, 'un tiers ne voit pas la position');
select ok(not private.can_receive_topic('location:' || (select v from ids)), 'un tiers ne peut pas rejoindre le canal');
select ok(not private.can_receive_topic('inbox:' || (select c1 from ids)), 'un tiers ne lit pas la boîte d''un autre');
reset role;

-- Avatars : visibles par les proches, pas par les tiers
insert into storage.objects (bucket_id, name) select 'avatars', v || '/avatar.jpg' from ids;
select pg_temp.as_user((select c1 from ids));
select is((select count(*)::int from storage.objects where bucket_id = 'avatars'), 1, 'le proche voit l''avatar de la victime');
reset role;
select pg_temp.as_user((select stranger from ids));
select is((select count(*)::int from storage.objects where bucket_id = 'avatars'), 0, 'un tiers ne voit pas l''avatar');
reset role;

-- Clôture « Je suis en sécurité »
set local role service_role;
create temp table rr as select svc_sos_resolve((select v from ids), null, 'resolved') as j;
reset role;
select is((select jsonb_array_length(j -> 'events') from rr), 1, 'SOS clos');
select is((select count(*)::int from sos_notifications where kind = 'resolved'), 4,
          'message « en sécurité » préparé pour chaque envoi réussi');

select pg_temp.as_user((select c1 from ids));
select is((select count(*)::int from sos_events), 0, 'le proche perd l''accès au SOS dès la clôture');
select is(get_live_location((select v from ids)), null, 'le proche perd l''accès à la position dès la clôture');
select ok(not private.can_receive_topic('location:' || (select v from ids)), 'le proche ne peut plus rejoindre le canal');
reset role;

-- SOS silencieux (code de contrainte) : invisible pour son auteur
set local role service_role;
create temp table rs as select svc_sos_start((select v from ids), gen_random_uuid(), 'duress_code', true) as j;
reset role;
select pg_temp.as_user((select v from ids));
select is((select count(*)::int from sos_events where status = 'active'), 0, 'SOS silencieux invisible pour la victime');
select is(get_dashboard() -> 'active_sos', 'null'::jsonb, 'aucun SOS actif affiché au tableau de bord de la victime');
reset role;
select pg_temp.as_user((select c1 from ids));
select is((select silent from sos_events where status = 'active'), true, 'le proche voit le SOS silencieux');
reset role;

select * from finish();
rollback;
