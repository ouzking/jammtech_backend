# JammTech — Backend Supabase

> « La paix dans votre poche ». Backend de l'application mobile de sécurité personnelle et de maison connectée
> [jammtech_mobile](https://github.com/ouzking/jammtech_mobile), pour le marché sénégalais.

Tout est versionné ici : migrations SQL, RLS, Edge Functions, seed, configuration Auth, CI/CD. **Aucune
modification manuelle dans le dashboard** qui ne soit pas reproduite dans ce dépôt.

| Document | Contenu |
|---|---|
| [docs/API.md](docs/API.md) | Contrat pour l'équipe mobile : tables, RPC, fonctions, exemples `supabase_flutter` |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Schéma, décisions, comparaison des fournisseurs SMS, hypothèses |

## Contenu

```
supabase/
  config.toml                 Auth téléphone + OTP, hook SMS, TOTP, limites, fonctions
  migrations/                 Schéma, RLS, triggers, RPC, Storage, pg_cron (ordre = incréments)
  functions/
    sos-trigger/              SOS confirmé → proches notifiés (push + SMS) en < 3 s, idempotent
    sos-resolve/              « Je suis en sécurité » / fausse alerte
    disarm/                   Désarmement + code de contrainte (SOS silencieux indiscernable)
    device-event/             Webhook générique des appareils (alertes, vidéos, présence)
    send-notification/        Notifications d'alertes (préférences, heures calmes)
    sos-track/                Suivi d'un SOS par lien web (proche sans l'app)
    purge-expired/            Purge des vidéos > 30 jours et des fichiers supprimés
    delete-account/           Suppression complète du compte
    auth-send-sms/            Hook Auth : envoi des OTP via nos fournisseurs SMS
    sms-status/               Accusés de livraison SMS
    _shared/                  HTTP, validation, SMS multi-fournisseurs, FCM, jetons, textes FR
    tests/                    Tests unitaires Deno + tests e2e (CI)
  tests/database/             Tests pgTAP (RLS A/B, SOS, contrainte, rétention, conformité)
  seed.sql                    Données de démo (= lib/data/demo_data.dart)
web/track/                    Page statique de suivi SOS (Leaflet + OpenStreetMap)
scripts/                      Banc de test SQL rapide, configuration Vault
.github/workflows/            CI/CD (tests → staging / production), sauvegarde quotidienne chiffrée
```

## Installation locale

Prérequis : Docker, [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started),
[Deno 2](https://deno.com).

```bash
cp supabase/.env.example supabase/.env
cp supabase/functions/.env.example supabase/functions/.env
supabase start                       # Postgres, Auth, Storage, Realtime, Studio…
supabase db reset                    # migrations + seed
supabase functions serve --env-file supabase/functions/.env
```

- Studio : http://127.0.0.1:54323 · API : http://127.0.0.1:54321
- Comptes de démo (mot de passe `JammTech2026!`) : **Moussa** `+221771234567`, **Awa** `+221770000001`.
  Code de désarmement `1234`, code de contrainte `9999`.
- En local, les SMS ne partent pas (`SMS_PROVIDERS=console`) : l'OTP s'affiche dans les journaux de
  `functions serve` (`SMS_CONSOLE_SHOW_BODY=true`).

### Tests

```bash
supabase test db                                   # pgTAP (référence)
deno fmt --check && deno lint && deno check supabase/functions/*/index.ts
deno test --allow-env --allow-net                  # unitaires
# e2e (pile locale démarrée + functions serve) :
eval "$(supabase status -o env)"; SUPABASE_URL=$API_URL SUPABASE_ANON_KEY=$ANON_KEY \
  SUPABASE_SERVICE_ROLE_KEY=$SERVICE_ROLE_KEY deno test --allow-env --allow-net supabase/functions/tests/e2e/
```

Banc SQL rapide sans la pile complète (Postgres Supabase seul dans Docker, avec des stubs Auth, Storage et
Realtime) : `scripts/test-db-local.sh`.

## Variables d'environnement et secrets

| Où | Variable | Rôle |
|---|---|---|
| `supabase/.env` (CLI) | `SEND_SMS_HOOK_URI`, `SEND_SMS_HOOK_SECRETS` | Hook Auth « Send SMS » |
| Secrets Edge Functions | `CRON_SECRET` | Appels internes (pg_cron → fonctions) |
| | `SMS_PROVIDERS` | Ordre de bascule : `orange,twilio`… |
| | `TWILIO_*`, `ORANGE_*`, `AT_*` | Identifiants des fournisseurs SMS |
| | `OTP_ALLOWED_PREFIXES` | Indicatifs autorisés pour les OTP (`+221`) |
| | `SEND_SMS_HOOK_SECRETS` | Vérification de la signature du hook |
| | `FCM_SERVICE_ACCOUNT` | Compte de service Firebase (JSON ou base64) |
| | `TRACK_TOKEN_SECRET`, `TRACK_PAGE_URL` | Liens de suivi SOS |
| | `SMS_STATUS_CALLBACK_URL`, `SMS_STATUS_WEBHOOK_KEY` | Accusés de livraison |
| | `ALLOWED_ORIGINS` | CORS (domaine de la page de suivi) |
| Vault (Postgres) | `project_url`, `cron_secret` | Utilisés par pg_cron (`scripts/configure-vault.sh`) |

`SUPABASE_URL` et `SUPABASE_SERVICE_ROLE_KEY` sont fournis automatiquement aux fonctions. **La clé
`service_role` ne quitte jamais le serveur ; l'app n'utilise que la clé `anon`.**

## Déploiement

La CI (`.github/workflows/ci.yml`) lance les tests sur chaque PR. Un push sur **`staging`** déploie
l'environnement GitHub `staging` ; un push sur **`main`** déploie `production`. Étapes : migrations, secrets
des fonctions, fonctions, configuration Auth (`config push`) puis secrets Vault.

### Mise en service (une fois par environnement)

1. **Créer le projet staging** sur Supabase (production : `pbaxnjannheurgyxhlkt`).
2. **GitHub → Settings → Environments** : créer `staging` et `production` (avec validation manuelle
   recommandée pour production), puis renseigner :
   - variable `SUPABASE_PROJECT_REF` ;
   - secrets `SUPABASE_ACCESS_TOKEN` (compte Supabase → Access Tokens), `SUPABASE_DB_PASSWORD`,
     `SUPABASE_DB_URL` (chaîne « Session pooler »), `SEND_SMS_HOOK_SECRETS` (`v1,whsec_<base64>`),
     `CRON_SECRET`, `FUNCTION_SECRETS_ENV` (contenu complet du fichier `.env` des fonctions, voir
     `supabase/functions/.env.example`) et, pour production, `BACKUP_PASSPHRASE`.
3. **Firebase** : créer le projet, ajouter les apps Android et iOS, téléverser la clé APNs, générer un compte
   de service → `FCM_SERVICE_ACCOUNT`.
4. **SMS** : ouvrir les comptes retenus (voir [ARCHITECTURE.md](docs/ARCHITECTURE.md#fournisseurs-sms--comparaison)),
   demander le Sender ID « JammTech », renseigner les identifiants et l'URL de callback
   `https://<ref>.supabase.co/functions/v1/sms-status`.
5. **Page de suivi** : déployer `web/track/` sur un hébergement statique HTTPS (Cloudflare Pages, Netlify,
   Vercel…). Adapter `web/track/config.js`, puis renseigner `TRACK_PAGE_URL` et `ALLOWED_ORIGINS`.
6. Pousser sur la branche. Le pipeline applique tout. **Le seed n'est jamais appliqué en dehors du local.**

Déploiement manuel équivalent :

```bash
supabase link --project-ref <ref>
supabase db push
supabase secrets set --env-file prod.env
supabase functions deploy
SEND_SMS_HOOK_URI=https://<ref>.supabase.co/functions/v1/auth-send-sms SEND_SMS_HOOK_SECRETS=… supabase config push
SUPABASE_DB_URL=… PROJECT_URL=https://<ref>.supabase.co CRON_SECRET=… ./scripts/configure-vault.sh
```

## Sauvegarde et restauration

- **Supabase** : sauvegardes quotidiennes automatiques (plan Pro, 7 jours ; PITR en option). Restauration :
  Dashboard → Database → Backups.
- **Dump chiffré quotidien** (`.github/workflows/backup.yml`) : rôles, schéma et données, chiffrés en AES-256
  et conservés 14 jours comme artefacts GitHub.

**Restaurer un dump** sur un projet vierge (ou un staging pour vérification) :

```bash
gpg --decrypt jammtech-<date>.tar.gz.gpg | tar -xz -C restore/
psql "$TARGET_DB_URL" -v ON_ERROR_STOP=1 \
  -f restore/roles.sql -f restore/schema.sql \
  -c 'SET session_replication_role = replica' -f restore/data.sql
# Puis : secrets des fonctions, déploiement des fonctions, config push, configure-vault.sh.
# Les fichiers Storage (avatars, vidéos) ne sont pas dans le dump : vidéos éphémères (30 j) ;
# avatars à recopier depuis le projet source si nécessaire.
```

Tester la restauration chaque trimestre sur le projet staging.

## Sécurité

- RLS sur 100 % des tables (test automatique) ; un utilisateur A ne peut ni lire ni modifier les données de B.
- Un proche ne voit la position **que** pendant un partage actif ou un SOS actif ; chaque accès est audité.
- Codes de désarmement et de contrainte hachés avec bcrypt ; verrouillage après 5 essais.
- Aucun numéro complet ni aucune position dans les journaux des fonctions.
- Signaler une vulnérabilité : contacter le responsable produit, pas de ticket public.
