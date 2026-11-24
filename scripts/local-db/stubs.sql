-- -----------------------------------------------------------------------------
-- Stubs pour le banc de test « Postgres seul » (scripts/test-db-local.sh).
-- Ils reproduisent la forme minimale des objets créés par les services Auth,
-- Storage et Realtime de Supabase. NE PAS utiliser ailleurs : la CI et
-- `supabase start` utilisent les vrais services.
-- -----------------------------------------------------------------------------

alter table auth.users add column if not exists phone text unique;
alter table auth.users add column if not exists phone_confirmed_at timestamptz;
alter table auth.users add column if not exists deleted_at timestamptz;
alter table auth.users add column if not exists email_change_token_new text;
alter table auth.users add column if not exists phone_change text;
alter table auth.users add column if not exists phone_change_token text;
alter table auth.users add column if not exists reauthentication_token text;
create table if not exists auth.identities (
  id uuid primary key default gen_random_uuid(),
  provider_id text not null,
  user_id uuid not null references auth.users (id) on delete cascade,
  identity_data jsonb not null,
  provider text not null,
  last_sign_in_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
);

create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                         (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')), '')::uuid
$$;

create table if not exists auth.sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  user_agent text,
  ip inet
);

create table if not exists storage.buckets (
  id text primary key,
  name text not null unique,
  owner uuid,
  public boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets (id),
  name text,
  owner uuid,
  metadata jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);
create or replace function storage.foldername(name text) returns text[] language plpgsql immutable as $$
declare _parts text[];
begin
  select string_to_array(name, '/') into _parts;
  return _parts[1:array_length(_parts, 1) - 1];
end
$$;
alter table storage.objects enable row level security;
grant usage on schema storage to authenticated, anon, service_role;
grant all on storage.objects, storage.buckets to authenticated, service_role;

create table if not exists realtime.messages (
  id bigint generated always as identity primary key,
  topic text not null,
  extension text not null,
  payload jsonb,
  event text,
  private boolean default false,
  inserted_at timestamptz default now()
);
alter table realtime.messages enable row level security;
grant usage on schema realtime to authenticated, service_role;
grant select on realtime.messages to authenticated;
create or replace function realtime.topic() returns text language sql stable as $$
  select nullif(current_setting('realtime.topic', true), '')
$$;
create or replace function realtime.send(payload jsonb, event text, topic text, private boolean default true)
returns void language sql security definer as $$
  insert into realtime.messages (topic, extension, payload, event, private)
  values (topic, 'broadcast', payload, event, private);
$$;
grant execute on function realtime.topic() to authenticated;
