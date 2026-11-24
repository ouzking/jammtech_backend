-- =============================================================================
-- Données de démonstration (équivalentes à lib/data/demo_data.dart de l'app).
-- UNIQUEMENT pour l'environnement local (`supabase db reset`). Jamais en
-- staging / production.
--
-- Comptes (mot de passe : JammTech2026!, OTP de test local : 123456) :
--   Moussa Ndiaye  +221771234567  — utilisateur principal
--   Awa Ndiaye     +221770000001  — épouse, proche inscrite (reçoit les SOS)
-- =============================================================================

do $$
declare
  moussa constant uuid := '11111111-1111-4111-8111-111111111111';
  awa constant uuid := '22222222-2222-4222-8222-222222222222';
  home uuid;
  cam_entree uuid := gen_random_uuid();
  cam_portail uuid := gen_random_uuid();
  cam_jardin uuid := gen_random_uuid();
  cam_salon uuid := gen_random_uuid();
  centrale uuid := gen_random_uuid();
  rec_v1 uuid := gen_random_uuid();
  rec_v2 uuid := gen_random_uuid();
  rec_v3 uuid := gen_random_uuid();
  rec_v4 uuid := gen_random_uuid();
  u record;
begin
  for u in
    select * from (values
      (moussa, '221771234567', 'Moussa Ndiaye'),
      (awa, '221770000001', 'Awa Ndiaye')
    ) as t(id, phone, full_name)
  loop
    insert into auth.users (
      instance_id, id, aud, role, phone, encrypted_password, phone_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change,
      phone_change, phone_change_token, reauthentication_token
    ) values (
      '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.phone,
      extensions.crypt('JammTech2026!', extensions.gen_salt('bf')), now(),
      '{"provider":"phone","providers":["phone"]}', jsonb_build_object('full_name', u.full_name), now(), now(),
      '', '', '', '', '', '', ''
    );
    insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (u.id::text, u.id, jsonb_build_object('sub', u.id::text, 'phone', u.phone, 'phone_verified', true),
            'phone', now(), now(), now());
  end loop;

  -- Contacts de confiance de Moussa (Awa est reliée automatiquement).
  insert into public.trusted_contacts (owner_id, name, relation, phone, priority) values
    (moussa, 'Awa Ndiaye', 'Épouse', '+221770000001', 1),
    (moussa, 'Ibrahima Fall', 'Frère', '+221760000002', 2),
    (moussa, 'Fatou Sarr', 'Voisine', '+221780000003', 3);

  -- Awa a l'app : elle reçoit les push (fournisseur « console » en local).
  insert into public.push_tokens (user_id, token, platform, device_label)
  values (awa, 'demo-fcm-token-awa-0001', 'android', 'Téléphone d''Awa');

  -- Codes de démo : désarmement 1234, contrainte 9999.
  insert into public.security_codes (user_id, disarm_code_hash, duress_code_hash) values
    (moussa, extensions.crypt('1234', extensions.gen_salt('bf', 10)), extensions.crypt('9999', extensions.gen_salt('bf', 10)));

  select home_id into home from public.home_members where user_id = moussa and role = 'owner' limit 1;
  update public.homes set arm_mode = 'home', arm_mode_changed_by = moussa where id = home;

  insert into public.devices (id, home_id, type, name, room, is_on, is_online, last_seen_at, firmware_version, state) values
    (cam_entree, home, 'camera', 'Entrée principale', 'Entrée', true, true, now(), '2.4.1', '{}'),
    (cam_portail, home, 'camera', 'Portail', 'Extérieur', true, true, now(), '2.4.1', '{}'),
    (cam_jardin, home, 'camera', 'Jardin', 'Jardin', true, false, now() - interval '65 minutes', '2.4.1', '{}'),
    (cam_salon, home, 'camera', 'Salon', 'Salon', true, true, now(), '2.4.1', '{}'),
    (gen_random_uuid(), home, 'camera', 'Garage', 'Garage', true, true, now(), '2.4.1', '{}'),
    (centrale, home, 'siren', 'Sirène', 'Centrale', false, true, now(), '2.4.1', '{}'),
    (gen_random_uuid(), home, 'light', 'Éclairage', 'Extérieur', true, true, now(), null, '{}'),
    (gen_random_uuid(), home, 'lock', 'Serrure', 'Porte d''entrée', true, true, now(), null, '{}'),
    (gen_random_uuid(), home, 'sensor', 'Porte du garage', 'Garage', true, true, now(), null, '{"open": false}');

  insert into public.recordings (id, home_id, device_id, title, storage_path, thumbnail_path, duration_seconds,
                                 motion_detected, uploaded, started_at, expires_at) values
    (rec_v1, home, cam_entree, 'Intrusion détectée', home || '/' || rec_v1 || '.mp4', home || '/' || rec_v1 || '.jpg',
     42, true, true, now() - interval '2 minutes', now() - interval '2 minutes' + interval '30 days'),
    (rec_v2, home, cam_portail, 'Livraison', home || '/' || rec_v2 || '.mp4', home || '/' || rec_v2 || '.jpg',
     68, false, true, now() - interval '3 hours 12 minutes', now() - interval '3 hours 12 minutes' + interval '30 days'),
    (rec_v3, home, cam_jardin, 'Mouvement détecté', home || '/' || rec_v3 || '.mp4', home || '/' || rec_v3 || '.jpg',
     27, true, true, now() - interval '1 day 1 hour', now() - interval '1 day 1 hour' + interval '30 days'),
    (rec_v4, home, cam_salon, 'Enregistrement manuel', home || '/' || rec_v4 || '.mp4', home || '/' || rec_v4 || '.jpg',
     231, false, true, now() - interval '4 days 6 hours', now() - interval '4 days 6 hours' + interval '30 days');

  insert into public.security_alerts (user_id, home_id, category, title, description, severity, location_label,
                                      device_id, recording_id, created_at, resolved_at, resolved_by, notified_at) values
    (null, home, 'intrusion', 'Intrusion détectée',
     'Mouvement détecté par la caméra de l''entrée alors que le système était armé. Un enregistrement de 42 secondes est disponible.',
     'critical', 'Entrée principale', cam_entree, rec_v1, now() - interval '2 minutes', null, null, now()),
    (moussa, null, 'zone', 'Zone à risque signalée',
     'Plusieurs signalements d''incidents ont été remontés à moins de 500 m de votre position au cours de la dernière heure.',
     'warning', 'Plateau, Dakar', null, null, now() - interval '18 minutes', null, null, now()),
    (null, home, 'device', 'Caméra hors ligne',
     'La caméra du jardin ne répond plus. Vérifiez son alimentation et la connexion Wi-Fi.',
     'info', 'Jardin', cam_jardin, null, now() - interval '65 minutes', null, null, now()),
    (null, home, 'device', 'Porte restée ouverte',
     'Le capteur de la porte du garage indique une ouverture depuis plus de 10 minutes.',
     'warning', 'Garage', null, null, now() - interval '5 hours', now() - interval '4 hours', moussa, now()),
    (null, home, 'system', 'Mise à jour installée',
     'Le micrologiciel de votre centrale a été mis à jour (v2.4.1). Aucune action requise.',
     'info', 'Centrale', centrale, null, now() - interval '26 hours', now() - interval '25 hours', moussa, now());

  -- Zone à risque : deux signalements récents au Plateau.
  insert into public.risk_reports (reported_by, category, description, lat, lng, created_at) values
    (awa, 'theft', 'Vol à l''arraché signalé', 14.6694, -17.4381, now() - interval '20 minutes'),
    (awa, 'suspicious', 'Individus suspects près du marché', 14.6702, -17.4369, now() - interval '35 minutes');
end;
$$;
