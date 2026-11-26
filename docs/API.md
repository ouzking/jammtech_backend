# Contrat API JammTech — équipe mobile

Client Flutter : `supabase_flutter`, **clé `anon` (publishable) uniquement**. Toutes les tables sont protégées
par RLS : une requête ne renvoie jamais les données d'un autre utilisateur, elle renvoie simplement « rien ».

- Projet production : `https://pbaxnjannheurgyxhlkt.supabase.co`
- Horodatages : UTC (`timestamptz`, ISO-8601). Affichage en `Africa/Dakar` côté app.
- Téléphones : E.164 (`+221771234567`). Les RPC acceptent aussi « 77 123 45 67 » et normalisent.
- Erreurs des Edge Functions : `{ "error": { "code": "...", "message": "texte FR affichable", "details": [...] } }`.
- Erreurs PostgREST / RPC : `PostgrestException` ; `message` est en français pour les erreurs métier.

```dart
final supabase = Supabase.instance.client;
```

---

## 1. Authentification (téléphone + mot de passe, OTP SMS)

| Étape | Appel |
|---|---|
| Inscription | `supabase.auth.signUp(phone: '+221771234567', password: pwd, data: {'full_name': 'Moussa Ndiaye'})` → OTP envoyé |
| Vérification OTP | `supabase.auth.verifyOTP(type: OtpType.sms, phone: phone, token: '123456')` |
| Renvoyer le code (≥ 30 s) | `supabase.auth.resend(type: OtpType.sms, phone: phone)` |
| Connexion | `supabase.auth.signInWithPassword(phone: phone, password: pwd)` |
| Mot de passe oublié 1/3 | `supabase.auth.signInWithOtp(phone: phone, shouldCreateUser: false)` |
| Mot de passe oublié 2/3 | `supabase.auth.verifyOTP(type: OtpType.sms, phone: phone, token: code)` → session |
| Mot de passe oublié 3/3 | `supabase.auth.updateUser(UserAttributes(password: newPwd))` |
| Déconnexion | `supabase.auth.signOut()` |

Mot de passe : 8 caractères minimum, lettres + chiffres. Limites : 30 s entre deux codes, 5 SMS/heure et
10/jour par numéro (erreur 429 avec message FR), seuls les numéros **+221** reçoivent un OTP pour l'instant.

Le profil, les réglages, les préférences et une maison « Résidence principale » sont **créés automatiquement**
à l'inscription.

### Double authentification (TOTP)

```dart
final f = await supabase.auth.mfa.enroll(factorType: FactorType.totp);   // QR code : f.totp.qrCode
final c = await supabase.auth.mfa.challenge(factorId: f.id);
await supabase.auth.mfa.verify(factorId: f.id, challengeId: c.id, code: '123456');
```

### Appareils connectés

```dart
final sessions = await supabase.rpc('list_my_sessions');
// [{id, created_at, updated_at, user_agent, ip, is_current}]
await supabase.rpc('revoke_session', params: {'p_session_id': id});
await supabase.auth.signOut(scope: SignOutScope.others); // tout sauf cet appareil
```

---

## 2. Accueil et profil : `get_dashboard()` (un seul aller-retour)

```dart
final d = await supabase.rpc('get_dashboard'); // ou params: {'p_home_id': id}
```

```jsonc
{
  "profile": {"id": "…", "full_name": "Moussa Ndiaye", "phone": "+221771234567", "avatar_url": "<uid>/avatar.jpg", "language": "fr", "plan": "free"},
  "home": {"id": "…", "name": "Résidence principale", "arm_mode": "home", "arm_mode_changed_at": "…", "role": "owner"},
  "homes_count": 1,
  "cameras": {"online": 4, "total": 5},
  "devices_count": 9,
  "contacts_count": 3,
  "protected_people_count": 0,
  "alerts": {"total": 5, "unresolved": 3, "critical_unresolved": 1},
  "recent_alerts": [{"id": "…", "title": "…", "description": "…", "severity": "critical", "category": "intrusion", "location_label": "Entrée principale", "created_at": "…", "resolved": false}],
  "active_sos": null,                 // ou {"id", "started_at"} (jamais un SOS silencieux)
  "location_sharing": null,           // ou {"id", "expires_at"}
  "protected_sos": [],                // personnes que je protège actuellement en SOS
  "protection_active": true
}
```

### Profil

```dart
await supabase.from('profiles').update({'full_name': 'Moussa N.', 'language': 'wo'}).eq('id', uid);
// phone et plan ne sont pas modifiables (erreur 42501).
```

**Avatar** — bucket privé `avatars`, chemin **`<user_id>/avatar.jpg`**. Redimensionner à 600 px max avant
l'envoi ; 1 Mo max ; jpeg/png/webp.

```dart
await supabase.storage.from('avatars').uploadBinary('$uid/avatar.jpg', bytes,
    fileOptions: const FileOptions(upsert: true, contentType: 'image/jpeg'));
await supabase.from('profiles').update({'avatar_url': '$uid/avatar.jpg'}).eq('id', uid);
final url = await supabase.storage.from('avatars').createSignedUrl(path, 3600);
```

---

## 3. Contacts de confiance (max 5)

```dart
final contacts = await supabase.from('trusted_contacts').select().order('priority');
await supabase.from('trusted_contacts').insert({
  'owner_id': uid, 'name': 'Awa Ndiaye', 'relation': 'Épouse', 'phone': '+221770000001', 'priority': 1,
});
await supabase.from('trusted_contacts').update({'priority': 2}).eq('id', id);
await supabase.from('trusted_contacts').delete().eq('id', id);
```

Colonnes : `id, owner_id, name, relation, phone, contact_user_id, priority, created_at, updated_at`.
`contact_user_id` est rempli par le serveur si le proche a un compte **vérifié** (il reçoit alors les push et
peut suivre la position). Erreurs : `P0001` « Vous ne pouvez pas avoir plus de 5 contacts de confiance »,
`23505` numéro déjà présent, `23514` numéro invalide.

Côté proche :

```dart
await supabase.rpc('get_people_i_protect'); // [{owner_id, full_name, phone, avatar_url, relation}]
await supabase.rpc('leave_trusted_contact', params: {'p_owner_id': id});
```

---

## 4. SOS

L'app gère l'appui de 3 s et le compte à rebours de 5 s, puis appelle le backend **une seule fois** avec une
clé d'idempotence générée **au moment de la confirmation** et réutilisée pour tous les nouveaux essais réseau.

```dart
final clientKey = const Uuid().v4(); // à conserver jusqu'au succès
final res = await supabase.functions.invoke('sos-trigger', body: {
  'client_key': clientKey,
  'lat': pos.latitude, 'lng': pos.longitude, 'accuracy_m': pos.accuracy, // si disponible
});
// res.data : {sos_event_id, status:"active", started_at, created, location_shared,
//             notified: {push, sms, failed}}
```

- Réessayer avec **la même** `client_key` en cas d'échec réseau : aucun doublon d'envoi.
- Pendant le SOS, envoyer la position (toutes les ~10 m) : `push_location` (voir §5).
- Tous les proches reçoivent un push (s'ils ont l'app) **et** un SMS avec un lien de suivi web.

**« Je suis en sécurité »**

```dart
await supabase.functions.invoke('sos-resolve', body: {'outcome': 'resolved'}); // ou 'cancelled' (fausse alerte)
// {closed: 1, outcome}
```

Optionnel : `code` (code de désarmement) pour clore aussi un SOS silencieux. Si le **code de contrainte** est
saisi ici, la réponse est un succès mais rien n'est clos (protection contre l'annulation forcée).

**Historique** : `supabase.from('sos_events').select().order('started_at', ascending: false)` et
`supabase.from('sos_notifications').select().eq('sos_event_id', id)` (statuts `queued|sent|delivered|failed`).

### Côté proche (temps réel)

Canal privé personnel : `inbox:<mon_user_id>`. Événements : `sos_started`, `sos_closed`,
`location_share_started`, `location_share_stopped`.

```dart
await supabase.realtime.setAuth(); // JWT courant
supabase.channel('inbox:$uid', opts: const RealtimeChannelConfig(private: true))
  .onBroadcast(event: 'sos_started', callback: (p) { /* p: {user_id, sos_event_id, silent, started_at} */ })
  .onBroadcast(event: 'sos_closed', callback: (p) { /* fermer l'écran de suivi */ })
  .subscribe();
```

Le push SOS contient `data: {type: "sos" | "sos_silent", sos_event_id, user_id}`.
**Si `silent` / `sos_silent` : afficher « Alerte discrète — ne l'appelez pas ».**

---

## 5. Position et carte

```dart
// À appeler sans condition quand l'app a une position (SOS, partage, suivi discret).
// Ne stocke rien et ne renvoie rien si aucun partage / SOS n'est actif.
await supabase.rpc('push_location', params: {'p_lat': lat, 'p_lng': lng, 'p_accuracy_m': acc, 'p_recorded_at': ts.toIso8601String()});

await supabase.rpc('start_location_share', params: {'p_duration_minutes': 480}); // 5 min à 24 h
await supabase.rpc('stop_location_share');
```

Suivi d'une personne protégée :

```dart
final live = await supabase.rpc('get_live_location', params: {'p_user_id': ownerId, 'p_trail_minutes': 30});
// null si aucun partage/SOS actif ; sinon {user_id, sos: {id, started_at, silent, trigger} | null,
//                                          trail: [{lat, lng, accuracy_m, recorded_at}]}
supabase.channel('location:$ownerId', opts: const RealtimeChannelConfig(private: true))
  .onBroadcast(event: 'position', callback: (p) { /* {user_id, lat, lng, accuracy_m, recorded_at, sos_event_id} */ })
  .subscribe();
```

L'accès est **refusé dès la fin** du partage ou du SOS. Chaque consultation est auditée et visible par la
personne suivie (`audit_log`, action `location.viewed`).

**Suivi discret (code de contrainte)** : le téléphone de la victime reçoit un push **de données uniquement**
`{type: "silent_tracking", sos_event_id}`. L'app doit alors démarrer l'envoi de position en arrière-plan
(`push_location`) **sans aucun affichage**.

### Zones à risque

```dart
final risks = await supabase.rpc('nearby_risks', params: {'p_lat': lat, 'p_lng': lng, 'p_radius_m': 500, 'p_since_minutes': 60});
// [{id, category, description, lat, lng (arrondis ~100 m), distance_m, created_at}]
await supabase.from('risk_reports').insert({'reported_by': uid, 'category': 'theft', 'description': '…', 'lat': lat, 'lng': lng});
// catégories : theft | assault | suspicious | accident | fire | other ; 5 signalements/heure max
```

---

## 6. Maison et appareils

```dart
final homes = await supabase.from('homes').select('*, home_members(user_id, role)');
final devices = await supabase.from('devices').select().eq('home_id', homeId).order('type');
// {id, home_id, type: camera|siren|light|lock|sensor, name, room, is_on, is_online, last_seen_at, firmware_version, state}
await supabase.from('devices').update({'is_on': true}).eq('id', deviceId); // membres
```

**Mode d'armement**

```dart
// Présence / Absence :
final r = await supabase.rpc('set_arm_mode', params: {'p_home_id': homeId, 'p_mode': 'away', 'p_client_device': 'Pixel 8'});
// {home_id, arm_mode, arm_mode_changed_at, warnings: [{device_id, name, room, code, message}]}
// codes : device_offline | sensor_open | lock_unlocked  → afficher avant/après armement

// Désarmement (TOUJOURS via cette fonction, avec la position si disponible) :
final d = await supabase.functions.invoke('disarm', body: {
  'home_id': homeId, 'code': saisie, 'client_device': 'Pixel 8', 'lat': lat, 'lng': lng, 'accuracy_m': acc,
});
// 200 {home_id, arm_mode: "disarmed", arm_mode_changed_at, warnings: []}
// 401 invalid_code « Code incorrect » ; 429 locked (5 essais → 5 min)
```

> ⚠️ **Code de contrainte** : la réponse est identique à un désarmement réussi. L'app ne doit **rien** faire de
> différent (pas de message, pas de vibration, pas d'appel supplémentaire conditionnel). Envoyer la position
> **à chaque** désarmement, pas seulement « parfois ».

Journal : `supabase.from('arm_mode_log').select().eq('home_id', homeId).order('changed_at', ascending: false)`.
Temps réel : canal privé `home:<home_id>`, événements `arm_mode` et `alert`.

**Codes de sécurité** (le PIN et la biométrie de déverrouillage de l'app restent locaux) :

```dart
await supabase.rpc('get_security_codes_status'); // {has_disarm_code, has_duress_code}
await supabase.rpc('set_security_codes', params: {
  'p_current_disarm_code': null,   // obligatoire si un code existe déjà
  'p_new_disarm_code': '1234',     // null = inchangé, '' = supprimer
  'p_new_duress_code': '9999',     // doit être différent
});
```

**Ajout d'appareil / membre** (propriétaire) :

```dart
final r = await supabase.rpc('register_device', params: {'p_home_id': homeId, 'p_type': 'camera', 'p_name': 'Portail', 'p_room': 'Extérieur'});
// {device: {...}, ingest_token: "<device_id>.<secret>"} → à transmettre UNE fois à l'appareil / la passerelle
await supabase.rpc('rotate_device_secret', params: {'p_device_id': id});
await supabase.rpc('add_home_member', params: {'p_home_id': homeId, 'p_phone': '+221770000001'});
```

---

## 7. Alertes

```dart
var q = supabase.from('security_alerts').select();
// Filtres de l'écran :
q = q.isFilter('resolved_at', null);          // « À traiter »
q = q.eq('severity', 'critical');             // « Critiques »
q = q.not('resolved_at', 'is', null);         // « Traitées »
final alerts = await q.order('created_at', ascending: false).limit(50);

await supabase.rpc('resolve_alert', params: {'p_alert_id': id});                    // traiter
await supabase.rpc('resolve_alert', params: {'p_alert_id': id, 'p_resolved': false}); // rouvrir
await supabase.rpc('resolve_all_alerts');                                           // → nombre
```

Colonnes : `id, user_id, home_id, category (intrusion|zone|device|contact|system), title, description,
severity (critical|warning|info), location_label, device_id, recording_id, resolved_at, resolved_by, created_at`.
Push d'alerte : `data: {type: "alert", alert_id, severity, recording_id}` ; canaux Android `critical`,
`alerts`, `sos` à créer dans l'app.

---

## 8. Enregistrements vidéo

```dart
final videos = await supabase.from('recordings')
  .select('*, devices(name, room)')
  .eq('home_id', homeId)
  .eq('uploaded', true)
  .order('started_at', ascending: false);
// filtre « mouvement » : .eq('motion_detected', true)

final url = await supabase.storage.from('recordings').createSignedUrl(v['storage_path'], 300); // 5 min
final thumb = await supabase.storage.from('recordings').createSignedUrl(v['thumbnail_path'], 300);
await supabase.from('recordings').delete().eq('id', id); // propriétaire ; fichiers supprimés sous 5 min
```

Conservation : 30 jours (`expires_at`), suppression automatique des lignes et des fichiers.
Réglage « vidéos en Wi-Fi uniquement » : appliqué par l'app (`user_settings.videos_wifi_only`).

---

## 9. Réglages et notifications

```dart
await supabase.from('user_settings').select().single();
await supabase.from('user_settings').update({'background_location': true}).eq('user_id', uid);
// precise_location, background_location, auto_share_on_sos, videos_wifi_only, anonymous_stats

await supabase.from('notification_preferences').select().single();
await supabase.from('notification_preferences').update({
  'intrusions_push': true, 'zones_sms': false, 'quiet_hours_enabled': true,
  'quiet_hours_start': '22:00', 'quiet_hours_end': '07:00', 'sound': true, 'vibration': true,
}).eq('user_id', uid);
```

Types : `intrusions`, `zones`, `devices`, `contacts` × canaux `push`, `sms`. Heures calmes (heure de Dakar) :
pas de SMS et push silencieux, **sauf alertes critiques et SOS** (jamais filtrés).

**Token push** (au démarrage et à chaque `onTokenRefresh`) :

```dart
await supabase.rpc('register_push_token', params: {'p_token': fcmToken, 'p_platform': 'android', 'p_device_label': 'Pixel 8'});
// à la déconnexion :
await supabase.from('push_tokens').delete().eq('token', fcmToken);
```

---

## 10. Conformité

```dart
final export = await supabase.rpc('export_my_data');          // JSON complet (à proposer en fichier)
await supabase.functions.invoke('delete-account', body: {'confirm': 'SUPPRIMER'}); // {deleted: true}
await supabase.auth.signOut();
final accessLog = await supabase.from('audit_log').select().order('created_at', ascending: false);
```

---

## 11. Correspondance avec les `// TODO` de l'app

| Écran / donnée de démo (`lib/data/demo_data.dart`) | Backend |
|---|---|
| `DemoData.userName`, `userPhone` | `get_dashboard().profile` |
| `DemoData.alerts`, `unresolvedCount`, `setResolved` | `security_alerts`, `get_dashboard().alerts`, `resolve_alert` |
| `DemoData.videos` | `recordings` + URL signées |
| `DemoData.contacts` | `trusted_contacts` |
| `DemoData.devices()` | `devices` (le tuile « Caméras » = `get_dashboard().cameras`) |
| `DemoData.emergencyNumbers` | reste **local** (17, 18, 1515, 800 00 20 20) |
| `ArmMode` | `homes.arm_mode` + `set_arm_mode` / `disarm` |
| Écran SOS | `sos-trigger`, `push_location`, `sos-resolve` |
| Carte | `push_location`, `start/stop_location_share`, `get_live_location`, `nearby_risks` |
| Transport (nouveau) | §12 `trip-*`, `get_trip_live`, `get_transport_summary`, `route_risks` ; §13 véhicules |

Valeurs d'énumération : `AlertSeverity` ↔ `critical|warning|info` ; `ArmMode` ↔ `disarmed|home|away`.

---

## 12. Trajets (« Trajet sécurisé »)

**L'escalade est faite par le serveur.** Si le téléphone est volé, éteint ou sans réseau, le serveur constate
le retard (pg_cron, chaque minute), demande « Tout va bien ? » puis déclenche le SOS tout seul.

### Démarrer

```dart
final clientKey = const Uuid().v4(); // à conserver jusqu'au succès (idempotence)
final r = await supabase.functions.invoke('trip-start', body: {
  'client_key': clientKey,
  'mode': 'taxi',                     // taxi | clando | moto | public | walk | car
  'destination': {'lat': 14.7167, 'lng': -17.4677, 'label': 'Maison, Mermoz'},
  'origin': {'lat': lat, 'lng': lng, 'label': 'Plateau'},           // facultatif
  'expected_arrival_at': eta.toUtc().toIso8601String(),              // futur, ≤ 24 h
  'grace_minutes': 15,                                               // 0..120 (défaut 15)
  'checkin_first_minutes': 3, 'checkin_second_minutes': 2,           // 1..15 (plus courts la nuit si souhaité)
  'watcher_contact_ids': [contactId1, contactId2],                   // défaut : tous les proches
  'vehicle_plate': 'DK-1234-AB',                                     // lue par OCR sur le téléphone
  'vehicle_note': 'Taxi jaune',
  'route': [[14.6928, -17.4467], [14.7167, -17.4677]],               // facultatif, 2..500 points
  'position': {'lat': lat, 'lng': lng, 'accuracy_m': acc},
});
// 200 {trip: {...}, created, watchers}   409 trip_already_active {details: {trip_id}}
```

Photo du véhicule (facultative) : bucket privé `vehicle-photos`, chemin **`<user_id>/<trip_id>.jpg`**, 1 Mo max.

```dart
await supabase.storage.from('vehicle-photos').uploadBinary('$uid/$tripId.jpg', bytes);
await supabase.rpc('set_trip_vehicle', params: {'p_trip_id': tripId, 'p_photo_path': '$uid/$tripId.jpg'});
```

Pendant le trajet : `push_location` comme d'habitude (les points sont rattachés au trajet). **Arrivée
automatique** à moins de 150 m de la destination.

### Pendant le trajet

```dart
await supabase.rpc('trip_extend', params: {'p_trip_id': tripId, 'p_minutes': 15}); // 5..120, 3 fois max
await supabase.rpc('trip_battery_low', params: {'p_trip_id': tripId, 'p_level': 8, 'p_lat': lat, 'p_lng': lng});
// ≤ 15 % : les proches sont prévenus une fois, avec la dernière position.

// Réponse au « Tout va bien ? » (push data.type = trip_checkin) :
final ok = await supabase.functions.invoke('trip-checkin',
    body: {'trip_id': tripId, 'code': saisie, 'lat': lat, 'lng': lng});
// 200 {ok: true, trip_id, next_check_after}   401 invalid_code   429 locked   404 not_found
```

> ⚠️ **Code de contrainte** accepté ici : réponse **identique** au code normal. L'app ne doit rien faire de
> différent. Un SOS silencieux part chez les proches ; le trajet reste dans le même état visible.

```dart
await supabase.functions.invoke('trip-arrive', body: {'trip_id': tripId}); // « Je suis arrivé·e »
await supabase.functions.invoke('trip-cancel', body: {'trip_id': tripId}); // {…, watchers_notified}
```

Escalade : « Tout va bien ? » (tour 1) → relance après `checkin_first_minutes` (tour 2, + SMS) → **SOS** après
`checkin_second_minutes` sans réponse. Déclencheurs : retard au-delà de la marge, aucune position depuis 10 min,
immobile 10 min loin de la destination, écart de plus de 1 km à l'itinéraire. Après un « oui », pas de nouvelle
question pendant 10 min. Un SOS pendant un trajet rattache le trajet au SOS (`trips.sos_event_id`).

### Côté proche

```dart
await supabase.rpc('get_trips_i_watch'); // [{trip_id, status, mode, destination_label, expected_arrival_at, traveler}]
final live = await supabase.rpc('get_trip_live', params: {'p_trip_id': tripId});
// null si je ne suis pas watcher ou si le trajet est terminé ; sinon trip + traveler, vehicle_plate,
// vehicle_photo_path, last_battery, late_minutes, trail [{lat, lng, accuracy_m, recorded_at}]
supabase.channel('trip:$tripId', opts: const RealtimeChannelConfig(private: true))
  .onBroadcast(event: 'position', callback: (p) {})  // {trip_id, lat, lng, accuracy_m, recorded_at}
  .onBroadcast(event: 'status', callback: (p) {})    // {trip_id, status, expected_arrival_at?}
  .subscribe();
// Photo : storage.from('vehicle-photos').createSignedUrl(vehicle_photo_path, 300)
```

Canal `inbox:<mon_id>` : événement `trip_started`. Les proches sans l'app reçoivent un SMS avec un lien de
suivi web (véhicule, heure prévue, position) qui cesse de fonctionner à la fin du trajet.

| `data.type` (push) | Destinataire | Effet dans l'app |
|---|---|---|
| `trip_started` | proche | Ouvrir le suivi du trajet (`data.trip_id`) |
| `trip_checkin` | voyageur | Écran plein « Tout va bien ? » + saisie du code (`data.round` 1 ou 2) |
| `trip_late` | proche | « Pas encore arrivé·e, retard de `data.late_minutes` min » |
| `trip_arrived` | proche | « Arrivé·e à … » (`data.arrived_at`) |
| `trip_cancelled` | proche | Trajet annulé |
| `trip_battery_low` | proche | Dernière position connue (`data.level`) |
| `sos` / `sos_silent` | proches | Escalade : identique à un SOS |

Les heures calmes ne s'appliquent **jamais** aux trajets.

### Résumé et itinéraire

```dart
await supabase.rpc('get_transport_summary');
// {active_trip, watched_trips, recent_trips, vehicles}
await supabase.rpc('route_risks', params: {'p_route': [[lat, lng], ...], 'p_since_minutes': 720, 'p_buffer_m': 300});
// {count, night, by_category: {theft: 2, …}, reports: [{id, category, lat, lng, created_at}]}
```

Historique : `supabase.from('trips').select().order('started_at', ascending: false)` et `trip_events`.
Conservation : 30 jours (90 jours si un SOS y est rattaché), photo comprise.

## 13. Véhicules et traceurs GPS (phase 2)

Modèle et ingestion prêts. **Aucune commande à distance** (coupure moteur) : hors périmètre.

```dart
await supabase.from('vehicles').insert({'id': vid, 'owner_id': uid, 'type': 'car',
    'plate': 'DK 5678 CD', 'brand_model': 'Toyota Corolla', 'color': 'Gris'});
// photo : vehicle-photos/<uid>/v_<vehicle_id>.jpg puis update photo_path
await supabase.rpc('add_vehicle_member', params: {'p_vehicle_id': vid, 'p_phone': '+221770000001'});
await supabase.from('vehicle_rules').update({'allowed_start': '06:00', 'allowed_end': '22:00',
    'night_ignition_alert': true, 'geofence_alert': true}).eq('vehicle_id', vid);
await supabase.from('vehicle_geofences').insert({'vehicle_id': vid, 'name': 'Maison',
    'center_lat': 14.7167, 'center_lng': -17.4677, 'radius_m': 300});
final t = await supabase.rpc('register_tracker', params: {'p_vehicle_id': vid, 'p_name': 'Boîtier',
    'p_model': 'teltonika', 'p_imei': '356307042441013'});
// {tracker, ingest_token} → à configurer UNE fois dans la passerelle du traceur
await supabase.from('tracker_positions').select().eq('vehicle_id', vid).order('recorded_at', ascending: false).limit(500);
```

Alertes (`security_alerts.category = 'vehicle'`, `vehicle_id`) : traceur débranché, choc, contact moteur la nuit,
mouvement hors des heures autorisées, sortie de zone, traceur hors ligne (30 min). Elles suivent les
préférences « intrusions ».

**Passerelle → backend** : `POST /functions/v1/tracker-event`, `Authorization: Bearer <tracker_id>.<secret>`

```json
{ "event_id": "imei-1732650000", "type": "position",
  "positions": [{"lat": 14.71, "lng": -17.46, "speed_kmh": 32, "heading": 90, "ignition": true,
                 "recorded_at": "2026-11-26T20:14:00Z"}],
  "external_power": true, "battery": 92 }
```

Types : `position`, `heartbeat`, `ignition`, `power`, `battery`, `shock` ; jusqu'à 100 positions par appel ;
`event_id` unique par traceur (idempotence).
