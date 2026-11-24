-- Incrément 5 : maisons, membres, appareils, mode d'armement.
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

select plan(22);

create temp table ids as
select pg_temp.new_user('+221774440001', 'Owner') as o,
       pg_temp.new_user('+221774440002', 'Member') as m,
       pg_temp.new_user('+221774440003', 'Other') as x;
alter table ids add column h uuid;
update ids set h = (select home_id from home_members where user_id = ids.o);
grant select on ids to public;

select pg_temp.as_user((select o from ids));
create temp table reg as select register_device((select h from ids), 'camera', 'Entrée', 'Entrée') as j;
grant select on reg to public;
select register_device((select h from ids), 'sensor', 'Porte garage', 'Garage');
select register_device((select h from ids), 'lock', 'Serrure', 'Porte');
select ok((select j ->> 'ingest_token' from reg) ~ '^[0-9a-f-]{36}\.[0-9a-f]{64}$', 'jeton d''ingestion renvoyé une fois');
select lives_ok($$ select add_home_member((select h from ids), '77 444 00 02') $$, 'ajout d''un membre par téléphone');
select throws_ok($$ update homes set arm_mode = 'away' $$, '42501', null, 'mode non modifiable directement');
select throws_ok($$ select set_arm_mode((select h from ids), 'disarmed') $$, '22023', null,
                 'désarmement uniquement via la fonction disarm');
reset role;

update devices set is_online = true, state = '{"open": true}' where type = 'sensor' and home_id = (select h from ids);
update devices set is_online = true, is_on = false where type = 'lock' and home_id = (select h from ids);

select pg_temp.as_user((select m from ids));
create temp table arm as select set_arm_mode((select h from ids), 'away', 'Pixel 8') as j;
select is((select j ->> 'arm_mode' from arm), 'away', 'un membre arme en mode Absence');
select ok((select j -> 'warnings' @> '[{"code": "device_offline"}]' from arm), 'avertissement caméra hors ligne');
select ok((select j -> 'warnings' @> '[{"code": "sensor_open"}]' from arm), 'avertissement porte ouverte');
select ok((select j -> 'warnings' @> '[{"code": "lock_unlocked"}]' from arm), 'avertissement serrure ouverte');
select is((select count(*)::int from arm_mode_log where mode = 'away' and client_device = 'Pixel 8'
           and changed_by = (select m from ids)), 1, 'changement journalisé (qui, quand, appareil)');
select is((select count(*)::int from devices), 3, 'le membre voit les appareils');
update devices set is_on = true where type = 'lock';
select is((select count(*)::int from devices where type = 'lock' and is_on), 1, 'le membre peut piloter un appareil');
delete from devices;
select is((select count(*)::int from devices), 3, 'le membre ne peut pas supprimer d''appareil');
select throws_ok($$ update devices set is_online = true $$, '42501', null, 'is_online réservé aux appareils');
select throws_ok($$ select register_device((select h from ids), 'camera', 'X') $$, '42501', null,
                 'seul le propriétaire ajoute un appareil');
reset role;

-- Un tiers ne voit rien
select pg_temp.as_user((select x from ids));
select is((select count(*)::int from homes where id = (select h from ids)), 0, 'un tiers ne voit pas la maison');
select is((select count(*)::int from devices where home_id = (select h from ids)), 0, 'un tiers ne voit pas les appareils');
select is((select count(*)::int from arm_mode_log where home_id = (select h from ids)), 0, 'un tiers ne voit pas le journal');
select throws_ok($$ select set_arm_mode((select h from ids), 'home') $$, '42501', null, 'un tiers ne peut pas armer');
select throws_ok($$ insert into home_members (home_id, user_id, role) values ((select h from ids), auth.uid(), 'owner') $$,
                 '42501', null, 'un tiers ne peut pas s''ajouter comme membre');
reset role;

-- Authentification d'appareil
set local role service_role;
select ok(svc_authenticate_device(
  split_part((select j ->> 'ingest_token' from reg), '.', 1)::uuid,
  split_part((select j ->> 'ingest_token' from reg), '.', 2)) is not null, 'appareil authentifié avec son secret');
select ok(svc_authenticate_device(
  split_part((select j ->> 'ingest_token' from reg), '.', 1)::uuid, repeat('0', 64)) is null, 'mauvais secret refusé');
reset role;

-- Une maison garde au moins un propriétaire
select throws_ok($$ delete from home_members where user_id = (select o from ids) and home_id = (select h from ids) $$,
                 'P0001', null, 'impossible de retirer le dernier propriétaire');

select * from finish();
rollback;
