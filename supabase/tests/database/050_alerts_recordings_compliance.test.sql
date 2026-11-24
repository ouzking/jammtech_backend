-- Incréments 6 à 9 : alertes, vidéos, zones à risque, tableau de bord,
-- rétention, export et suppression de compte.
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

select plan(30);

create temp table ids as
select pg_temp.new_user('+221775550001', 'Alice') as a, pg_temp.new_user('+221775550002', 'Bob') as b;
alter table ids add column ha uuid, add column hb uuid, add column cam uuid, add column rec uuid, add column old_rec uuid;
update ids set ha = (select home_id from home_members where user_id = ids.a),
               hb = (select home_id from home_members where user_id = ids.b);
update ids set cam = gen_random_uuid(), rec = gen_random_uuid(), old_rec = gen_random_uuid();
insert into devices (id, home_id, type, name, is_online, last_seen_at)
  select cam, ha, 'camera', 'Entrée', true, now() - interval '20 minutes' from ids;
insert into recordings (id, home_id, device_id, storage_path, thumbnail_path, motion_detected)
  select rec, ha, cam, ha || '/' || rec || '.mp4', ha || '/' || rec || '.jpg', true from ids;
insert into recordings (id, home_id, device_id, storage_path, started_at, expires_at)
  select old_rec, ha, cam, ha || '/' || old_rec || '.mp4', now() - interval '31 days', now() - interval '1 day' from ids;
insert into storage.objects (bucket_id, name) select 'recordings', ha || '/' || rec || '.mp4' from ids;
insert into storage.objects (bucket_id, name) select 'avatars', a || '/avatar.jpg' from ids;
select private.create_alert(null, (select ha from ids), 'intrusion', 'critical', 'Intrusion', 'desc', 'Entrée',
                            (select cam from ids), (select rec from ids), null, null);
select private.create_alert((select a from ids), null, 'zone', 'warning', 'Zone', 'desc', null, null, null, 'k1', null);
select is(private.create_alert((select a from ids), null, 'zone', 'warning', 'Zone', 'desc', null, null, null, 'k1', null),
          null, 'alerte dédoublonnée par clé');
grant select on ids to public;

-- Alertes
select pg_temp.as_user((select a from ids));
select is((select count(*)::int from security_alerts), 2, 'A voit ses alertes (maison + personnelles)');
select is((get_dashboard() -> 'alerts' ->> 'unresolved')::int, 2, 'tableau de bord : 2 alertes à traiter');
select is((get_dashboard() -> 'alerts' ->> 'critical_unresolved')::int, 1, 'tableau de bord : 1 critique');
select is((get_dashboard() -> 'cameras' ->> 'online')::int, 1, 'tableau de bord : caméras en ligne');
select ok((select resolved_at is not null from resolve_alert((select id from security_alerts where category = 'intrusion'))),
          'marquer comme traitée');
select ok((select resolved_at is null from resolve_alert((select id from security_alerts where category = 'intrusion'), false)),
          'rouvrir');
select is(resolve_all_alerts(), 2, 'tout marquer comme traité');
select throws_ok($$ update security_alerts set title = 'x' $$, '42501', null, 'alertes non modifiables directement');
reset role;

select pg_temp.as_user((select b from ids));
select is((select count(*)::int from security_alerts), 0, 'B ne voit pas les alertes de A');
select throws_ok($$ select resolve_alert((select id from security_alerts limit 1)) $$, '42501', null,
                 'B ne peut pas traiter les alertes de A (aucune ligne visible)');
select is(resolve_all_alerts(), 0, 'tout traiter n''affecte pas les alertes de A');
select is((select count(*)::int from recordings), 0, 'B ne voit pas les vidéos de A');
select is((select count(*)::int from storage.objects where bucket_id = 'recordings'), 0, 'B ne lit pas les fichiers vidéo de A');
select throws_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', (select a from ids) || '/x.jpg') $$,
                 '42501', null, 'B ne peut pas écrire dans le dossier avatar de A');
select lives_ok($$ insert into storage.objects (bucket_id, name) values ('avatars', auth.uid() || '/avatar.jpg') $$,
                'B écrit dans son propre dossier avatar');
reset role;

-- Vidéos
select pg_temp.as_user((select a from ids));
select is((select count(*)::int from storage.objects where bucket_id = 'recordings'), 1, 'A peut signer l''URL de sa vidéo');
delete from recordings where id = (select rec from ids);
reset role;
select is((select count(*)::int from private.storage_deletion_queue where path like '%' || (select rec from ids) || '%'), 2,
          'suppression d''une vidéo : fichier et miniature mis en file');
set local role service_role;
select is((select count(*)::int from svc_expired_recordings()), 1, 'vidéo de plus de 30 jours détectée pour purge');
reset role;
select is((select expires_at - started_at from recordings where id = (select old_rec from ids)) >= interval '30 days', true,
          'conservation par défaut de 30 jours');

-- Zones à risque
select pg_temp.as_user((select b from ids));
insert into risk_reports (reported_by, category, lat, lng) values (auth.uid(), 'theft', 16.0300, -16.4900);
select is((select count(*)::int from nearby_risks(16.0305, -16.4895, 500, 60)), 1, 'incident à moins de 500 m');
select is((select count(*)::int from nearby_risks(16.2000, -16.6000, 500, 60)), 0, 'incident hors rayon ignoré');
reset role;
select pg_temp.as_user((select a from ids));
select is((select count(*)::int from risk_reports), 0, 'les signalements des autres ne sont pas lisibles directement');
reset role;

-- Rétention
insert into location_points (user_id, lat, lng, recorded_at, created_at)
  select a, 14.7, -17.4, now() - interval '8 days', now() - interval '8 days' from ids;
select private.purge_retention();
select is((select count(*)::int from location_points where user_id = (select a from ids)), 0,
          'positions hors SOS purgées après 7 jours');

-- Appareils hors ligne
select cmp_ok(private.mark_devices_offline(), '>=', 1, 'caméra silencieuse marquée hors ligne');
select ok(exists (select 1 from security_alerts where dedupe_key = 'offline:' || (select cam from ids)),
          'alerte « Caméra hors ligne » créée');

-- Export et suppression de compte
select pg_temp.as_user((select a from ids));
select ok(export_my_data() ? 'profile', 'export des données personnelles');
reset role;
set local role service_role;
create temp table del as select svc_prepare_account_deletion((select a from ids)) as j;
reset role;
select is((select j -> 'avatar_paths' from del), jsonb_build_array((select a from ids) || '/avatar.jpg'),
          'fichiers avatar listés pour suppression');
delete from auth.users where id = (select a from ids);
select is((select count(*)::int from homes where id = (select ha from ids)), 0, 'maison supprimée avec le compte');
select ok((select count(*) from private.storage_deletion_queue where path like (select ha from ids) || '/%') >= 1,
          'fichiers vidéo de la maison mis en file de suppression');

select * from finish();
rollback;
