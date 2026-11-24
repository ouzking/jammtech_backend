-- =============================================================================
-- JammTech — Fondations : extensions, schéma privé, utilitaires communs.
-- =============================================================================
-- Conventions du projet :
--   * Toutes les tables vivent dans `public` (exposé par PostgREST) et ont la RLS
--     activée. Les droits sont accordés explicitement (REVOKE ALL puis GRANT),
--     sans jamais compter sur les privilèges par défaut.
--   * Le schéma `private` n'est PAS exposé par l'API : il contient les fonctions
--     d'aide SECURITY DEFINER utilisées par les politiques RLS et les tables
--     internes (files d'attente, limites de débit).
--   * Les fonctions `public.svc_*` ne sont exécutables que par `service_role`
--     (Edge Functions). Les fonctions RPC destinées à l'app sont exécutables par
--     `authenticated` uniquement.
--   * Tous les horodatages sont en `timestamptz` (UTC).
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;
create extension if not exists postgis with schema extensions;
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault with schema vault;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
-- USAGE est nécessaire pour que les politiques RLS appellent les fonctions
-- d'aide ; le schéma n'est pas exposé par PostgREST et chaque fonction garde
-- un EXECUTE explicite.
grant usage on schema private to authenticated, service_role;

-- Par défaut, aucune nouvelle fonction n'est exécutable par tout le monde :
-- chaque migration accorde explicitement EXECUTE aux rôles concernés.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema private revoke execute on functions from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Types énumérés
-- -----------------------------------------------------------------------------
create type public.app_language as enum ('fr', 'wo', 'en');
create type public.arm_mode as enum ('disarmed', 'home', 'away');
create type public.home_role as enum ('owner', 'member');
create type public.device_type as enum ('camera', 'siren', 'light', 'lock', 'sensor');
create type public.alert_severity as enum ('critical', 'warning', 'info');
create type public.alert_category as enum ('intrusion', 'zone', 'device', 'contact', 'system');
create type public.sos_status as enum ('active', 'resolved', 'cancelled');
create type public.sos_trigger as enum ('button', 'duress_code');
create type public.notification_channel as enum ('push', 'sms');
create type public.notification_status as enum ('queued', 'sent', 'delivered', 'failed');
create type public.push_platform as enum ('android', 'ios', 'web');
create type public.risk_category as enum ('theft', 'assault', 'suspicious', 'accident', 'fire', 'other');

-- -----------------------------------------------------------------------------
-- Utilitaires
-- -----------------------------------------------------------------------------

-- Validation d'un numéro de téléphone au format E.164.
-- Pour le Sénégal (+221), on impose en plus 9 chiffres commençant par 7
-- (mobile) ou 3 (fixe). Les autres indicatifs sont acceptés (diaspora).
create or replace function private.is_valid_phone(p text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p is not null
     and p ~ '^\+[1-9][0-9]{7,14}$'
     and (left(p, 4) <> '+221' or p ~ '^\+221[37][0-9]{8}$');
$$;

-- Normalise un numéro saisi librement (« +221 77 123 45 67 », « 00221... »,
-- « 771234567 ») vers E.164. Renvoie NULL si le résultat est invalide.
create or replace function private.normalize_phone(p text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  digits text;
  result text;
begin
  if p is null then
    return null;
  end if;
  digits := regexp_replace(p, '[^0-9+]', '', 'g');
  if digits like '00%' then
    digits := '+' || substr(digits, 3);
  elsif digits ~ '^[37][0-9]{8}$' then
    digits := '+221' || digits;
  elsif digits ~ '^[1-9][0-9]{7,14}$' then
    digits := '+' || digits;
  end if;
  result := digits;
  if private.is_valid_phone(result) then
    return result;
  end if;
  return null;
end;
$$;

create or replace function private.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- Lecture d'un secret Vault (URL du projet, clé de service pour pg_cron…).
create or replace function private.get_secret(p_name text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select decrypted_secret from vault.decrypted_secrets where name = p_name limit 1;
$$;
revoke execute on function private.get_secret(text) from public;

-- -----------------------------------------------------------------------------
-- Journal d'audit (accès aux positions, changements sensibles).
-- Ne contient JAMAIS de coordonnées.
-- -----------------------------------------------------------------------------
create table public.audit_log (
  id bigint generated always as identity primary key,
  actor_id uuid references auth.users (id) on delete cascade,
  subject_user_id uuid references auth.users (id) on delete cascade,
  action text not null check (length(action) between 1 and 64),
  target_table text,
  target_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
comment on table public.audit_log is
  'Journal d''audit. Ne doit contenir aucune coordonnée ni donnée de position.';
create index audit_log_subject_idx on public.audit_log (subject_user_id, created_at desc);
create index audit_log_actor_idx on public.audit_log (actor_id, created_at desc);
create index audit_log_created_idx on public.audit_log (created_at);

alter table public.audit_log enable row level security;
revoke all on public.audit_log from anon, authenticated;
grant select on public.audit_log to authenticated;
grant all on public.audit_log to service_role;

-- Un utilisateur voit les accès effectués à SES données (transparence),
-- ainsi que ses propres actions.
create policy audit_log_select_own on public.audit_log
  for select to authenticated
  using (subject_user_id = (select auth.uid()) or actor_id = (select auth.uid()));

create or replace function private.audit(
  p_action text,
  p_subject uuid,
  p_target_table text default null,
  p_target_id text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_log (actor_id, subject_user_id, action, target_table, target_id, metadata)
  values (auth.uid(), p_subject, p_action, p_target_table, p_target_id, coalesce(p_metadata, '{}'::jsonb));
$$;
