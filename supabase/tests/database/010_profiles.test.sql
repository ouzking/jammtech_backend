-- Incrément 1 : profils, réglages, préférences, tokens push, codes de sécurité.
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
select pg_temp.new_user('+221771110001', 'Alice A') as a, pg_temp.new_user('+221771110002', 'Bob B') as b;
grant select on ids to public;

-- Création automatique à l'inscription
select is((select full_name from profiles where id = (select a from ids)), 'Alice A', 'profil créé avec le nom');
select is((select phone from profiles where id = (select a from ids)), '+221771110001', 'téléphone normalisé en E.164');
select ok(exists (select 1 from user_settings where user_id = (select a from ids)), 'réglages créés');
select ok(exists (select 1 from notification_preferences where user_id = (select a from ids)), 'préférences créées');
select is((select count(*)::int from home_members where user_id = (select a from ids) and role = 'owner'), 1,
          'maison par défaut créée, utilisateur propriétaire');

-- Validation des numéros
select ok(private.is_valid_phone('+221771234567'), 'mobile sénégalais valide');
select ok(private.is_valid_phone('+221338211234'), 'fixe sénégalais valide');
select ok(not private.is_valid_phone('+221571234567'), 'numéro sénégalais commençant par 5 refusé');
select ok(not private.is_valid_phone('+22177123456'), 'numéro sénégalais à 8 chiffres refusé');
select is(private.normalize_phone('77 123 45 67'), '+221771234567', 'normalisation d''un numéro local');
select ok(private.is_valid_phone('+33612345678'), 'numéro étranger E.164 accepté (diaspora)');

-- Isolation A / B
select pg_temp.as_user((select a from ids));
select is((select count(*)::int from profiles), 1, 'A ne voit que son profil');
select is((select count(*)::int from user_settings), 1, 'A ne voit que ses réglages');
update profiles set full_name = 'Piraté' where id = (select b from ids);
update notification_preferences set sound = false where user_id = (select b from ids);
select throws_ok($$ update profiles set phone = '+221771119999' where id = auth.uid() $$, '42501',
                 null, 'le téléphone n''est pas modifiable par le client');
select throws_ok($$ update profiles set plan = 'premium' where id = auth.uid() $$, '42501',
                 null, 'le plan n''est pas modifiable par le client');
select lives_ok($$ select register_push_token('token-alice-0000000001', 'android', 'Pixel') $$, 'enregistrement token push');
select throws_ok($$ select * from security_codes $$, '42501', null, 'security_codes illisible par le client');
reset role;

select is((select full_name from profiles where id = (select b from ids)), 'Bob B', 'A n''a pas pu modifier le profil de B');
select is((select sound from notification_preferences where user_id = (select b from ids)), true,
          'A n''a pas pu modifier les préférences de B');

-- Un token push passe au dernier compte connecté sur l'appareil
select pg_temp.as_user((select b from ids));
select register_push_token('token-alice-0000000001', 'android', 'Pixel');
reset role;
select is((select user_id from push_tokens where token = 'token-alice-0000000001'), (select b from ids),
          'token réattribué au nouvel utilisateur');

select * from finish();
rollback;
