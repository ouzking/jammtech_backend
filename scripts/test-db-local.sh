#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Banc de test SQL rapide, sans la pile Supabase complète :
#   1. lance l'image Postgres de Supabase dans Docker ;
#   2. applique des stubs Auth / Storage / Realtime (scripts/local-db/stubs.sql) ;
#   3. applique toutes les migrations puis le seed ;
#   4. exécute les tests pgTAP de supabase/tests/database.
# La référence reste `supabase test db` (utilisée par la CI).
#
# Usage : scripts/test-db-local.sh [--keep]   (--keep : laisse le conteneur)
# -----------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${PG_IMAGE:-public.ecr.aws/supabase/postgres:17.6.1.167}"
NAME="jammtech-testdb"
KEEP="${1:-}"

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -e POSTGRES_PASSWORD=postgres "$IMAGE" >/dev/null
trap '[ "$KEEP" = "--keep" ] || docker rm -f "$NAME" >/dev/null 2>&1' EXIT

# L'image démarre un serveur temporaire pendant son initialisation puis le
# redémarre : on attend le second « ready to accept connections » et trois
# connexions réussies d'affilée.
ok=0
for _ in $(seq 1 240); do
  ready="$(docker logs "$NAME" 2>&1 | grep -c 'ready to accept connections' || true)"
  if [ "$ready" -ge 2 ] && docker exec "$NAME" psql -U supabase_admin -d postgres -Atc 'select 1' >/dev/null 2>&1; then
    ok=$((ok + 1))
    [ "$ok" -ge 3 ] && break
  else
    ok=0
  fi
  sleep 2
done

psql_file() {
  docker exec -i "$NAME" psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q -f - < "$1"
}

echo "→ stubs"
psql_file "$ROOT/scripts/local-db/stubs.sql" >/dev/null
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "→ $(basename "$f")"
  psql_file "$f" >/dev/null
done
echo "→ seed.sql"
psql_file "$ROOT/supabase/seed.sql" >/dev/null

docker exec "$NAME" psql -U supabase_admin -d postgres -qc "create extension if not exists pgtap with schema extensions" >/dev/null

failed=0
for t in "$ROOT"/supabase/tests/database/*.sql; do
  out="$(docker exec -i "$NAME" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 -f - < "$t" 2>&1)" || true
  if echo "$out" | grep -qE '^not ok|ERROR|Looks like'; then
    echo "✗ $(basename "$t")"
    echo "$out" | grep -E '^not ok|ERROR|#' | head -40
    failed=1
  else
    echo "✓ $(basename "$t") ($(echo "$out" | grep -c '^ok') assertions)"
  fi
done
exit $failed
