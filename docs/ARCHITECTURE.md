# Architecture et décisions — JammTech backend

## Vue d'ensemble

```
App Flutter (clé anon + JWT) ──► PostgREST (tables + RPC, RLS) ──► Postgres 17 + PostGIS
          │                     ──► Realtime (Broadcast privé)        │  pg_cron ──► pg_net ──┐
          └──► Edge Functions ──► service_role (svc_*)  ◄─────────────┘                       │
                 │  sos-trigger · sos-resolve · disarm · delete-account                      │
                 │  device-event (appareils) · sos-track (lien web) · sms-status (webhooks)  │
                 │  send-notification · purge-expired  ◄──────────────────────────────────────┘
                 │  auth-send-sms (hook Auth)
                 ├──► FCM HTTP v1 (Android + iOS/APNs)
                 └──► SMS : Twilio | Orange SMS API | Africa's Talking (bascule ordonnée)
```

### Schéma (résumé)

```
auth.users 1─1 profiles ─┬─ user_settings · notification_preferences · push_tokens
                         ├─ security_codes (bcrypt : désarmement, contrainte)
                         ├─ trusted_contacts (≤ 5) ── contact_user_id → auth.users (numéro vérifié)
                         ├─ home_members (owner|member) ── homes ─┬─ devices ─┬─ device_credentials (sha256)
                         │                                       │           └─ device_events (30 j)
                         │                                       ├─ arm_mode_log
                         │                                       ├─ recordings (30 j) ── storage « recordings »
                         │                                       └─ security_alerts
                         ├─ sos_events ─┬─ sos_notifications (push|sms, queued→sent→delivered|failed)
                         │              └─ location_shares (fenêtres de visibilité)
                         ├─ location_points (PostGIS ; 7 j, 90 j si SOS)
                         ├─ risk_reports (PostGIS, GiST)
                         └─ audit_log (sans coordonnées)
private.* : storage_deletion_queue, otp_sms_log, fonctions d'aide RLS
```

## Décisions

| # | Décision | Pourquoi |
|---|---|---|
| D1 | **RLS sur 100 % des tables**, droits accordés explicitement (`REVOKE ALL` puis `GRANT` par colonne). Test automatique qui échoue si une table n'a pas la RLS. | Exigence non négociable ; les droits par colonne empêchent de modifier `phone`, `plan`, `arm_mode`, `contact_user_id`, `is_online`… |
| D2 | Écritures sensibles **uniquement via RPC `SECURITY DEFINER`** ou Edge Functions (`svc_*` réservées à `service_role`). | Les règles métier (journalisation, contrôles, idempotence) ne peuvent pas être contournées par un client. |
| D3 | **SOS idempotent** : `unique (user_id, client_key)` + un seul SOS actif par utilisateur + verrou consultatif. | Un nouvel essai réseau ne renvoie jamais de doublon. |
| D4 | SOS : **une seule RPC** prépare tout (événement, partage, notifications `queued`, destinataires, tokens), puis push et SMS partent **en parallèle** avec un délai de 2,5 s par envoi. Les statuts sont enregistrés en un lot. | Objectif < 3 s : 2 allers-retours base + envois parallèles. Les notifications restées `queued` plus de 10 s sont renvoyées au prochain rejeu. |
| D5 | **SMS de secours systématique** pour chaque proche, même s'il a l'app. Plafond anti-abus : au-delà de 10 SOS/24 h, les SMS sont journalisés `failed: rate_limited` (les push partent toujours). | La data mobile n'est pas garantie ; le plafond protège la facture sans jamais bloquer un SOS. |
| D6 | **Code de contrainte** vérifié côté serveur avec **deux comparaisons bcrypt systématiques** ; réponse identique ; SOS envoyé en tâche de fond (`EdgeRuntime.waitUntil`). Le SOS silencieux est invisible pour son auteur (RLS, tableau de bord, export, journal). Un push de données invisible demande à l'app de partager la position en arrière-plan. | Indiscernable d'un désarmement réel, y compris en temps de réponse. |
| D7 | Le code de désarmement est **vérifié côté serveur** ; le PIN et la biométrie de l'app restent locaux (déverrouillage de l'app). | Si le désarmement était vérifié localement, le code de contrainte ne pourrait pas rester indiscernable. |
| D8 | Positions : enregistrées **uniquement pendant une fenêtre active** (partage manuel ≤ 24 h ou SOS). Lecture par les proches via RPC auditée + Broadcast privé (`location:<uid>`), autorisé par RLS sur `realtime.messages`. | Minimisation des données ; l'accès se ferme à la clôture (aucune diffusion ni lecture ensuite). |
| D9 | **Lien de suivi web** : jeton HMAC sans état de 70 caractères, dans le **fragment** de l'URL, propre à chaque proche, 72 h max. Plus aucune position après la clôture. Page statique `web/track/` à héberger (Cloudflare Pages / Netlify / Vercel). | Supabase ne sert pas de HTML depuis une Edge Function ; le fragment n'apparaît pas dans les journaux des serveurs. |
| D10 | Rattachement d'un proche à un compte (`contact_user_id`) **seulement si son numéro est vérifié par OTP**. | Sinon, s'inscrire avec le numéro d'un proche permettrait de recevoir des positions. |
| D11 | Vidéos : bucket privé, URL signées de 5 min, upload par l'appareil via URL d'upload signée. Suppression des fichiers via une **file** vidée par l'API Storage (pg_cron → `purge-expired`). | La suppression directe dans `storage.objects` est interdite par Supabase. |
| D12 | Appareils : webhook générique `device-event`, jeton par appareil `<id>.<secret>` (empreinte SHA-256 stockée), idempotence par `event_id`. Champ `devices.state` (jsonb) prévu pour le direct vidéo (`stream_url`) en v2. | Indépendant des fabricants. |
| D13 | OTP via **hook Auth « Send SMS »** : même chaîne de fournisseurs que le SOS, indicatifs autorisés (+221), 5 SMS/h et 10/jour par numéro, en plus des limites par IP de Supabase Auth. | Contrôle des coûts et protection contre le « SMS pumping ». |
| D14 | Notifications d'alerte : immédiates depuis `device-event`, avec un **balayage pg_cron** chaque minute pour celles qui n'ont pas pu partir. Heures calmes : pas de SMS et push silencieux, sauf `critical`. | Fiabilité au moins une fois, sans dépendre d'un seul appel. |
| D15 | Double authentification : **TOTP** (gratuit). Le MFA par SMS de Supabase est une option payante. | Coût. |
| D16 | Avatars redimensionnés **par l'app** (600 px), bucket limité à 1 Mo et aux images. | La transformation d'images côté serveur nécessite le plan Pro. |

## Fournisseurs SMS — comparaison

Critères : délivrabilité sur Orange / Free / Expresso, coût, latence, accusés de livraison, Sender ID.

| | Twilio | Orange SMS API (Sonatel) | Africa's Talking | Vonage |
|---|---|---|---|---|
| Couverture SN | Internationale, via agrégateurs | Opérateur historique : excellente sur Orange ; inter-opérateurs à valider | Panafricaine ; couverture SN à confirmer contractuellement | Internationale |
| Accusés de livraison | Oui (webhook signé) | Oui (abonnement) | Oui (callback) | Oui |
| Sender ID alphanumérique | Selon enregistrement local | Oui (« JammTech », sur demande) | Oui (sur demande) | Selon pays |
| Intégration | Très simple, SDK et doc de référence | OAuth2 + REST, packs prépayés | REST simple | REST simple |
| Coût | Le plus élevé en général | Le plus bas en local (packs) | Intermédiaire | Intermédiaire |

**Recommandation** : `SMS_PROVIDERS=orange,twilio`. Orange en principal (coût local, réseau majoritaire),
Twilio en secours automatique (fiabilité, autre route). **À valider avant production** :

1. devis réels et tests de délivrabilité sur des numéros Orange, Free et Expresso (latence, taux de réception) ;
2. enregistrement du Sender ID « JammTech » ;
3. budget mensuel (voir ci-dessous).

Le code supporte les trois fournisseurs et l'ordre se change par secret, **sans redéploiement**.

**Estimation du volume** : OTP ≈ 1,3 SMS par inscription + mots de passe oubliés. Un SOS = jusqu'à 5 SMS
(alerte), plus 5 « en sécurité ». Un SMS de SOS avec lien de suivi fait environ 2 segments.

## Hypothèses retenues (questions ouvertes du brief)

| Question | Choix par défaut (modifiable) |
|---|---|
| Budget SMS | SMS de secours systématique ; plafond de 10 SOS avec SMS par utilisateur et par 24 h |
| Suivi par lien web pour un proche sans l'app | Oui (`sos-track` + `web/track`) |
| Conservation des positions | 7 jours hors SOS, 90 jours pour les SOS, puis effacement |
| Premiers modèles de caméras / capteurs | Interface générique ; adaptateurs par passerelle à écrire |
| Abonnement | Pas en v1 ; colonne `profiles.plan` (`free|premium`) prête |
| Consentement du proche | Liaison automatique si le numéro est vérifié ; le proche peut se retirer (`leave_trusted_contact`) |

## Points d'attention et suite

- **Staging** : il faut un **deuxième projet Supabase** (les branches Supabase sont payantes). La CI déploie la
  branche `staging` vers l'environnement GitHub `staging`, et `main` vers `production`.
- **Realtime** : l'autorisation d'un canal est vérifiée à la connexion. À la clôture, plus aucune position n'est
  diffusée et l'événement `sos_closed` est envoyé ; l'app doit quitter le canal.
- **Audit** : les lectures via RPC et via le lien web sont journalisées. Les messages Broadcast reçus ne le
  sont pas individuellement.
- **Wolof / anglais** : les textes sont centralisés dans `supabase/functions/_shared/messages.ts` ;
  `profiles.language` est déjà disponible.
- **Commandes vers les appareils** (sirène, serrure) : `devices.is_on` est mis à jour par l'app. La passerelle
  doit écouter le canal `home:<id>` ou interroger l'API. Le protocole de commande est à définir avec le
  fournisseur de matériel.
