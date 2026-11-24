-- Socle de sécurité : RLS sur 100 % des tables, aucun droit `anon`,
-- fonctions de service fermées aux clients.
begin;
create extension if not exists pgtap with schema extensions;
set search_path = public, extensions;

select plan(7);

select is(
  (select count(*)::int from pg_tables where schemaname = 'public' and not rowsecurity),
  0,
  'RLS activée sur toutes les tables du schéma public'
);

select is(
  (select coalesce(string_agg(tablename, ', '), '') from pg_tables where schemaname = 'public' and not rowsecurity),
  '',
  'aucune table public sans RLS (liste)'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
   where table_schema = 'public' and grantee = 'anon'),
  0,
  'aucun droit de table accordé au rôle anon'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
   where table_schema = 'private' and grantee in ('anon', 'authenticated')),
  0,
  'aucun droit sur les tables du schéma private pour les clients'
);

select is(
  (select coalesce(string_agg(p.proname, ', '), '')
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname like 'svc\_%'
     and (has_function_privilege('authenticated', p.oid, 'execute')
          or has_function_privilege('anon', p.oid, 'execute'))),
  '',
  'les fonctions svc_* ne sont pas exécutables par les clients'
);

select is(
  (select coalesce(string_agg(p.proname, ', '), '')
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and has_function_privilege('anon', p.oid, 'execute')
     and p.proname not like 'st\_%' and p.proname not like '\_st\_%'
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')),
  '',
  'aucune fonction JammTech exécutable par anon'
);

select is(
  (select coalesce(string_agg(p.proname, ', '), '')
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname in ('public', 'private') and p.prosecdef
     and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
     and not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%')),
  '',
  'toutes les fonctions SECURITY DEFINER fixent leur search_path'
);

select * from finish();
rollback;
