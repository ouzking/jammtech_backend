-- Transport, phase 2 : véhicules et traceurs GPS (modèle, accès, ingestion).
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

select plan(20);

create temp table ids as
select pg_temp.new_user('+221777770001', 'Propriétaire') as o,
       pg_temp.new_user('+221777770002', 'Membre') as m,
       pg_temp.new_user('+221777770003', 'Inconnu') as s,
       gen_random_uuid() as v;
grant select on ids to public;

select pg_temp.as_user((select o from ids));
select lives_ok($$ insert into vehicles (id, owner_id, type, plate, brand_model, color)
                   values ((select v from ids), auth.uid(), 'car', 'dk 5678 cd', 'Toyota Corolla', 'Gris') $$,
                'le propriétaire ajoute son véhicule');
select is((select plate from vehicles), 'DK5678CD', 'plaque normalisée');
select is((select count(*)::int from vehicle_rules), 1, 'règles par défaut créées');
select lives_ok($$ select add_vehicle_member((select v from ids), '77 777 00 02') $$, 'partage avec un membre');
select throws_ok($$ update vehicles set photo_path = 'autre/chemin.jpg' $$, '22023', null, 'chemin de photo contrôlé');
create temp table reg as select register_tracker((select v from ids), 'Boîtier', 'teltonika', '356307042441013') as j;
grant select on reg to public;
select ok((select j ->> 'ingest_token' from reg) ~ '^[0-9a-f-]{36}\.[0-9a-f]{64}$', 'jeton d''ingestion du traceur');
reset role;

select pg_temp.as_user((select m from ids));
select is((select count(*)::int from vehicles), 1, 'le membre voit le véhicule');
select is((select count(*)::int from trackers), 1, 'le membre voit le traceur');
select throws_ok($$ select register_tracker((select v from ids)) $$, '42501', null, 'seul le propriétaire ajoute un traceur');
delete from vehicles;
select is((select count(*)::int from vehicles), 1, 'le membre ne supprime pas le véhicule');
select throws_ok($$ select * from tracker_credentials $$, '42501', null, 'secrets des traceurs illisibles');
reset role;

-- Ingestion (service)
set local role service_role;
select ok(svc_authenticate_tracker(split_part((select j ->> 'ingest_token' from reg), '.', 1)::uuid,
                                   split_part((select j ->> 'ingest_token' from reg), '.', 2)) is not null,
          'traceur authentifié');
select ok(svc_authenticate_tracker(split_part((select j ->> 'ingest_token' from reg), '.', 1)::uuid, repeat('0', 64)) is null,
          'mauvais secret refusé');
insert into tracker_positions (tracker_id, vehicle_id, lat, lng, speed_kmh, recorded_at)
  select (j -> 'tracker' ->> 'id')::uuid, (select v from ids), 14.7, -17.45, 30, now() from reg;
create temp table al as
  select svc_create_vehicle_alert((select v from ids), 'critical', 'Traceur débranché', 'test', 'power:x') as a1,
         svc_create_vehicle_alert((select v from ids), 'critical', 'Traceur débranché', 'test', 'power:x') as a2;
select is((select jsonb_array_length(svc_alert_recipients(a1) -> 'recipients') from al), 2,
          'alerte véhicule : propriétaire et membre prévenus');
reset role;
grant select on al to public;
select is((select a2 from al), null, 'alerte dédoublonnée');

select pg_temp.as_user((select m from ids));
select is((select count(*)::int from security_alerts where vehicle_id = (select v from ids)), 1, 'le membre voit l''alerte du véhicule');
select is((select count(*)::int from tracker_positions), 1, 'le membre voit les positions');
reset role;

select pg_temp.as_user((select s from ids));
select is((select count(*)::int from vehicles) + (select count(*)::int from trackers)
          + (select count(*)::int from tracker_positions)
          + (select count(*)::int from security_alerts where vehicle_id is not null), 0,
          'un inconnu ne voit ni véhicule, ni traceur, ni position, ni alerte');
reset role;

-- Rétention des positions : 30 jours
update tracker_positions set created_at = now() - interval '31 days';
select private.purge_retention();
select is((select count(*)::int from tracker_positions), 0, 'positions de traceur purgées après 30 jours');

-- Aucune fonction de commande moteur
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname ~ '(engine|immobil|cut|kill)'), 0,
          'aucune commande à distance (coupure moteur) exposée');

select * from finish();
rollback;
