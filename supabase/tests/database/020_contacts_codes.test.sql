-- Incrément 2 : contacts de confiance ; codes de désarmement / contrainte.
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
select pg_temp.new_user('+221772220001', 'Alice') as a,
       pg_temp.new_user('+221772220002', 'Bob') as b,
       pg_temp.new_user('+221772220003', 'Usurpateur', false) as unverified;
grant select on ids to public;

select pg_temp.as_user((select a from ids));
select lives_ok($$ insert into trusted_contacts (owner_id, name, relation, phone)
                   values (auth.uid(), 'Bob', 'Frère', '77 222 00 02') $$, 'ajout d''un proche (numéro local normalisé)');
select lives_ok($$ insert into trusted_contacts (owner_id, name, relation, phone, priority)
                   values (auth.uid(), 'Non vérifié', 'Ami', '+221772220003', 2) $$, 'ajout d''un proche non vérifié');
select throws_ok($$ insert into trusted_contacts (owner_id, name, phone) values ((select b from ids), 'X', '+221772229999') $$,
                 '42501', null, 'A ne peut pas créer un contact pour B');
select throws_ok($$ update trusted_contacts set contact_user_id = (select b from ids) $$, '42501', null,
                 'contact_user_id non modifiable par le client');
select throws_ok($$ insert into trusted_contacts (owner_id, name, phone) values (auth.uid(), 'Mauvais', '+221571234567') $$,
                 '23514', null, 'numéro invalide refusé');
reset role;

select is((select contact_user_id from trusted_contacts where phone = '+221772220002'), (select b from ids),
          'proche inscrit et vérifié relié automatiquement');
select is((select contact_user_id from trusted_contacts where phone = '+221772220003'), null,
          'proche au numéro NON vérifié non relié');

-- Vérification ultérieure du numéro → liaison
update auth.users set phone_confirmed_at = now() where id = (select unverified from ids);
select is((select contact_user_id from trusted_contacts where phone = '+221772220003'), (select unverified from ids),
          'liaison effectuée après vérification OTP');

-- Limite de 5
select pg_temp.as_user((select a from ids));
insert into trusted_contacts (owner_id, name, phone) values
  (auth.uid(), 'C3', '+221772220013'), (auth.uid(), 'C4', '+221772220014'), (auth.uid(), 'C5', '+221772220015');
select throws_ok($$ insert into trusted_contacts (owner_id, name, phone) values (auth.uid(), 'C6', '+221772220016') $$,
                 'P0001', 'Vous ne pouvez pas avoir plus de 5 contacts de confiance', 'maximum 5 proches');

-- Isolation : B ne voit pas la liste de A, mais sait qui il protège
reset role;
select pg_temp.as_user((select b from ids));
select is((select count(*)::int from trusted_contacts), 0, 'B ne voit pas les contacts de A');
select is((select count(*)::int from get_people_i_protect()), 1, 'B voit qu''il protège A');
delete from trusted_contacts;
reset role;
select is((select count(*)::int from trusted_contacts where owner_id = (select a from ids)), 5,
          'B ne peut pas supprimer les contacts de A');

-- Codes de sécurité
select pg_temp.as_user((select a from ids));
select is(get_security_codes_status(), '{"has_disarm_code": false, "has_duress_code": false}'::jsonb, 'aucun code au départ');
select lives_ok($$ select set_security_codes(null, '1234', '9999') $$, 'définition des codes');
select throws_ok($$ select set_security_codes('0000', '5555', null) $$, '28P01', null, 'changement refusé sans le code actuel');
select throws_ok($$ select set_security_codes('1234', '4321', '4321') $$, '22023', null,
                 'codes identiques refusés');
select throws_ok($$ select set_security_codes('1234', 'abcd', null) $$, '22023', null, 'code non numérique refusé');
select throws_ok($$ select svc_verify_disarm_code(auth.uid(), '1234') $$, '42501', null,
                 'vérification de code réservée au service');
reset role;

set local role service_role;
select is(svc_verify_disarm_code((select a from ids), '1234'), 'ok', 'code de désarmement reconnu');
select is(svc_verify_disarm_code((select a from ids), '9999'), 'duress', 'code de contrainte reconnu');
select is(svc_verify_disarm_code((select a from ids), '0000'), 'invalid', 'mauvais code');
select ok(not exists (select 1 from security_codes where disarm_code_hash like '%1234%' or duress_code_hash like '%9999%'),
          'codes stockés hachés');
reset role;

select * from finish();
rollback;
