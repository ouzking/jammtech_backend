#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Crée ou met à jour les secrets Vault utilisés par pg_cron pour appeler les
# Edge Functions (purge des vidéos, balayage des notifications).
#
# Variables requises :
#   SUPABASE_DB_URL  chaîne de connexion Postgres (session pooler ou directe)
#   PROJECT_URL      https://<ref>.supabase.co
#   CRON_SECRET      même valeur que le secret CRON_SECRET des Edge Functions
# Idempotent.
# -----------------------------------------------------------------------------
set -euo pipefail
: "${SUPABASE_DB_URL:?}" "${PROJECT_URL:?}" "${CRON_SECRET:?}"

psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -q \
  -v project_url="$PROJECT_URL" -v cron_secret="$CRON_SECRET" <<'SQL'
select set_config('jt.project_url', :'project_url', false);
select set_config('jt.cron_secret', :'cron_secret', false);
do $$
declare
  s record;
begin
  for s in select * from (values ('project_url', current_setting('jt.project_url')),
                                 ('cron_secret', current_setting('jt.cron_secret'))) v(name, value)
  loop
    if exists (select 1 from vault.secrets where name = s.name) then
      perform vault.update_secret((select id from vault.secrets where name = s.name), s.value);
    else
      perform vault.create_secret(s.value, s.name);
    end if;
  end loop;
end
$$;
SQL
echo "Secrets Vault à jour."
