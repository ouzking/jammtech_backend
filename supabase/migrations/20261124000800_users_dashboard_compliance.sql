-- =============================================================================
-- Cycle de vie utilisateur, tableau de bord, conformité (export / suppression)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Création automatique du profil et des réglages à l'inscription.
-- Le numéro n'est relié aux listes de proches QU'APRÈS vérification par OTP
-- (sinon un tiers pourrait s'inscrire avec le numéro d'un proche et recevoir
-- des positions).
-- -----------------------------------------------------------------------------
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  e164 text := case when new.phone is null or new.phone = '' then null
                    else private.normalize_phone('+' || ltrim(new.phone, '+')) end;
begin
  insert into public.profiles (id, full_name, phone)
  values (new.id, left(coalesce(new.raw_user_meta_data ->> 'full_name', ''), 100), e164)
  on conflict (id) do nothing;
  insert into public.user_settings (user_id) values (new.id) on conflict do nothing;
  insert into public.notification_preferences (user_id) values (new.id) on conflict do nothing;
  insert into public.homes (name, created_by) values ('Résidence principale', new.id);

  if e164 is not null and new.phone_confirmed_at is not null then
    perform private.link_contacts_for(new.id, e164);
  end if;
  return new;
end;
$$;

create or replace function private.handle_user_phone_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  e164 text := case when new.phone is null or new.phone = '' then null
                    else private.normalize_phone('+' || ltrim(new.phone, '+')) end;
begin
  update public.profiles set phone = e164 where id = new.id and phone is distinct from e164;
  if new.phone is distinct from old.phone then
    -- Ancien numéro : on délie les listes qui pointaient vers ce compte.
    update public.trusted_contacts set contact_user_id = null
     where contact_user_id = new.id and phone is distinct from e164;
  end if;
  if e164 is not null and new.phone_confirmed_at is not null then
    perform private.link_contacts_for(new.id, e164);
  end if;
  return new;
end;
$$;

create or replace function private.link_contacts_for(p_user uuid, p_phone text)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.trusted_contacts
     set contact_user_id = p_user
   where phone = p_phone and owner_id <> p_user and contact_user_id is distinct from p_user;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

create trigger on_auth_user_phone_changed
  after update of phone, phone_confirmed_at on auth.users
  for each row execute function private.handle_user_phone_change();

-- -----------------------------------------------------------------------------
-- Tableau de bord : un seul aller-retour pour l'écran d'accueil et le profil.
-- -----------------------------------------------------------------------------
create or replace function public.get_dashboard(p_home_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  uid uuid := auth.uid();
  hid uuid;
  result jsonb;
begin
  if uid is null then
    raise exception 'Authentification requise' using errcode = '42501';
  end if;

  select hm.home_id into hid
  from public.home_members hm
  join public.homes h on h.id = hm.home_id
  where hm.user_id = uid and (p_home_id is null or hm.home_id = p_home_id)
  order by (hm.role = 'owner') desc, h.created_at
  limit 1;

  select jsonb_build_object(
    'profile', (select jsonb_build_object('id', p.id, 'full_name', p.full_name, 'phone', p.phone,
                                          'avatar_url', p.avatar_url, 'language', p.language, 'plan', p.plan)
                from public.profiles p where p.id = uid),
    'home', (select jsonb_build_object('id', h.id, 'name', h.name, 'arm_mode', h.arm_mode,
                                       'arm_mode_changed_at', h.arm_mode_changed_at,
                                       'role', (select role from public.home_members where home_id = h.id and user_id = uid))
             from public.homes h where h.id = hid),
    'homes_count', (select count(*) from public.home_members where user_id = uid),
    'cameras', jsonb_build_object(
      'online', (select count(*) from public.devices where home_id = hid and type = 'camera' and is_online),
      'total', (select count(*) from public.devices where home_id = hid and type = 'camera')),
    'devices_count', (select count(*) from public.devices where home_id = hid),
    'contacts_count', (select count(*) from public.trusted_contacts where owner_id = uid),
    'protected_people_count', (select count(*) from public.trusted_contacts where contact_user_id = uid),
    'alerts', jsonb_build_object(
      'total', (select count(*) from public.security_alerts a
                where a.user_id = uid or a.home_id in (select home_id from public.home_members where user_id = uid)),
      'unresolved', (select count(*) from public.security_alerts a
                     where a.resolved_at is null
                       and (a.user_id = uid or a.home_id in (select home_id from public.home_members where user_id = uid))),
      'critical_unresolved', (select count(*) from public.security_alerts a
                              where a.resolved_at is null and a.severity = 'critical'
                                and (a.user_id = uid or a.home_id in (select home_id from public.home_members where user_id = uid)))),
    'recent_alerts', coalesce((
      select jsonb_agg(x order by x ->> 'created_at' desc) from (
        select jsonb_build_object('id', a.id, 'title', a.title, 'description', a.description,
                                  'severity', a.severity, 'category', a.category,
                                  'location_label', a.location_label, 'created_at', a.created_at,
                                  'resolved', a.resolved_at is not null) as x
        from public.security_alerts a
        where a.user_id = uid or a.home_id in (select home_id from public.home_members where user_id = uid)
        order by a.created_at desc
        limit 5) s), '[]'::jsonb),
    -- SOS actif visible (jamais un SOS silencieux).
    'active_sos', (select jsonb_build_object('id', e.id, 'started_at', e.started_at)
                   from public.sos_events e where e.user_id = uid and e.status = 'active' and not e.silent),
    'location_sharing', (select jsonb_build_object('id', s.id, 'expires_at', s.expires_at)
                         from public.location_shares s
                         where s.user_id = uid and s.sos_event_id is null and s.ended_at is null
                           and (s.expires_at is null or s.expires_at > now())
                         limit 1),
    -- Personnes protégées actuellement en SOS (côté proche).
    'protected_sos', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', e.user_id, 'sos_event_id', e.id, 'started_at', e.started_at,
                                          'silent', e.silent, 'full_name', p.full_name))
      from public.sos_events e
      join public.profiles p on p.id = e.user_id
      where e.status = 'active' and private.is_trusted_contact_of(e.user_id, uid)), '[]'::jsonb),
    'protection_active', (select h.arm_mode <> 'disarmed' from public.homes h where h.id = hid)
  ) into result;
  return result;
end;
$$;
grant execute on function public.get_dashboard(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Export des données personnelles (RGPD / loi sénégalaise 2008-12).
-- -----------------------------------------------------------------------------
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
  return jsonb_build_object(
    'exported_at', now(),
    'profile', (select to_jsonb(p) from public.profiles p where p.id = uid),
    'settings', (select to_jsonb(s) from public.user_settings s where s.user_id = uid),
    'notification_preferences', (select to_jsonb(n) from public.notification_preferences n where n.user_id = uid),
    'trusted_contacts', (select coalesce(jsonb_agg(to_jsonb(t)), '[]') from public.trusted_contacts t where t.owner_id = uid),
    'homes', (select coalesce(jsonb_agg(jsonb_build_object('home', to_jsonb(h), 'role', hm.role)), '[]')
              from public.home_members hm join public.homes h on h.id = hm.home_id where hm.user_id = uid),
    'devices', (select coalesce(jsonb_agg(to_jsonb(d)), '[]') from public.devices d
                where d.home_id in (select home_id from public.home_members where user_id = uid)),
    'security_alerts', (select coalesce(jsonb_agg(to_jsonb(a) - 'location'), '[]') from public.security_alerts a
                        where a.user_id = uid or a.home_id in (select home_id from public.home_members where user_id = uid)),
    'recordings', (select coalesce(jsonb_agg(to_jsonb(r)), '[]') from public.recordings r
                   where r.home_id in (select home_id from public.home_members where user_id = uid)),
    'sos_events', (select coalesce(jsonb_agg(to_jsonb(e) - 'last_location'), '[]') from public.sos_events e
                   where e.user_id = uid and not e.silent),
    'location_points', (select coalesce(jsonb_agg(jsonb_build_object('lat', lp.lat, 'lng', lp.lng,
                          'accuracy_m', lp.accuracy_m, 'recorded_at', lp.recorded_at)), '[]')
                        from public.location_points lp
                        where lp.user_id = uid
                          and (lp.sos_event_id is null
                               or not exists (select 1 from public.sos_events e where e.id = lp.sos_event_id and e.silent))),
    'risk_reports', (select coalesce(jsonb_agg(to_jsonb(r) - 'location'), '[]') from public.risk_reports r where r.reported_by = uid),
    'push_tokens', (select coalesce(jsonb_agg(jsonb_build_object('platform', platform, 'device_label', device_label,
                      'created_at', created_at)), '[]') from public.push_tokens where user_id = uid),
    'audit_log', (select coalesce(jsonb_agg(to_jsonb(l)), '[]') from public.audit_log l where l.subject_user_id = uid)
  );
end;
$$;
grant execute on function public.export_my_data() to authenticated;

-- -----------------------------------------------------------------------------
-- Suppression de compte : préparation (appelée par l'Edge Function
-- `delete-account` avant `auth.admin.deleteUser`).
--   * maisons dont l'utilisateur est le seul membre → supprimées (les
--     fichiers vidéo partent dans la file de suppression) ;
--   * maisons partagées dont il est le seul propriétaire → propriété
--     transférée au membre le plus ancien ;
--   * renvoie la liste des fichiers avatars à supprimer.
-- -----------------------------------------------------------------------------
create or replace function public.svc_prepare_account_deletion(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  h record;
  heir uuid;
  deleted_homes int := 0;
begin
  for h in select hm.home_id from public.home_members hm where hm.user_id = p_user_id loop
    if not exists (select 1 from public.home_members where home_id = h.home_id and user_id <> p_user_id) then
      delete from public.homes where id = h.home_id;
      deleted_homes := deleted_homes + 1;
    elsif not exists (select 1 from public.home_members
                      where home_id = h.home_id and user_id <> p_user_id and role = 'owner') then
      select user_id into heir from public.home_members
      where home_id = h.home_id and user_id <> p_user_id order by created_at limit 1;
      update public.home_members set role = 'owner' where home_id = h.home_id and user_id = heir;
    end if;
  end loop;

  -- Les SOS actifs sont clos (les proches perdent immédiatement l'accès).
  update public.sos_events set status = 'cancelled', resolved_at = now()
   where user_id = p_user_id and status = 'active';
  update public.location_shares set ended_at = now() where user_id = p_user_id and ended_at is null;

  return jsonb_build_object(
    'deleted_homes', deleted_homes,
    'avatar_paths', coalesce((select jsonb_agg(name) from storage.objects
                              where bucket_id = 'avatars' and name like p_user_id::text || '/%'), '[]'::jsonb)
  );
end;
$$;
revoke execute on function public.svc_prepare_account_deletion(uuid) from public, anon, authenticated;
grant execute on function public.svc_prepare_account_deletion(uuid) to service_role;
