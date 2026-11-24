-- =============================================================================
-- Incrément 2 — Contacts de confiance
-- =============================================================================

create table public.trusted_contacts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 100),
  relation text check (relation is null or length(relation) <= 50),
  phone text not null check (private.is_valid_phone(phone)),
  -- Renseigné automatiquement quand le proche possède un compte dont le numéro
  -- a été VÉRIFIÉ par OTP. Jamais modifiable par le client.
  contact_user_id uuid references auth.users (id) on delete set null,
  priority smallint not null default 1 check (priority between 1 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, phone),
  check (contact_user_id is null or contact_user_id <> owner_id)
);
create index trusted_contacts_owner_idx on public.trusted_contacts (owner_id, priority);
create index trusted_contacts_contact_user_idx on public.trusted_contacts (contact_user_id)
  where contact_user_id is not null;
create index trusted_contacts_phone_idx on public.trusted_contacts (phone);

create trigger trusted_contacts_updated_at before update on public.trusted_contacts
  for each row execute function private.set_updated_at();

-- Normalisation du numéro, limite de 5 proches, liaison au compte du proche.
create or replace function private.trusted_contacts_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  n int;
begin
  new.phone := coalesce(private.normalize_phone(new.phone), new.phone);
  new.name := btrim(new.name);

  if tg_op = 'INSERT' then
    -- Verrou par propriétaire pour rendre la limite fiable en concurrence.
    perform pg_advisory_xact_lock(hashtextextended('trusted_contacts:' || new.owner_id::text, 0));
    select count(*) into n from public.trusted_contacts where owner_id = new.owner_id;
    if n >= 5 then
      raise exception 'Vous ne pouvez pas avoir plus de 5 contacts de confiance' using errcode = 'P0001';
    end if;
  end if;

  if tg_op = 'INSERT' or new.phone is distinct from old.phone then
    select p.id into new.contact_user_id
    from public.profiles p
    join auth.users u on u.id = p.id
    where p.phone = new.phone
      and u.phone_confirmed_at is not null
      and p.id <> new.owner_id
    limit 1;
  end if;
  return new;
end;
$$;

create trigger trusted_contacts_before_write
  before insert or update on public.trusted_contacts
  for each row execute function private.trusted_contacts_before_write();

alter table public.trusted_contacts enable row level security;
revoke all on public.trusted_contacts from anon, authenticated;
grant select, delete on public.trusted_contacts to authenticated;
grant insert (owner_id, name, relation, phone, priority) on public.trusted_contacts to authenticated;
grant update (name, relation, phone, priority) on public.trusted_contacts to authenticated;
grant all on public.trusted_contacts to service_role;

create policy trusted_contacts_select_own on public.trusted_contacts
  for select to authenticated using (owner_id = (select auth.uid()));
create policy trusted_contacts_insert_own on public.trusted_contacts
  for insert to authenticated with check (owner_id = (select auth.uid()));
create policy trusted_contacts_update_own on public.trusted_contacts
  for update to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy trusted_contacts_delete_own on public.trusted_contacts
  for delete to authenticated using (owner_id = (select auth.uid()));

-- -----------------------------------------------------------------------------
-- Aides de relation, utilisées par les politiques RLS.
-- -----------------------------------------------------------------------------

-- Vrai si `p_viewer` est un proche (inscrit et vérifié) de `p_owner`.
create or replace function private.is_trusted_contact_of(p_owner uuid, p_viewer uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.trusted_contacts
    where owner_id = p_owner and contact_user_id = p_viewer
  );
$$;
grant execute on function private.is_trusted_contact_of(uuid, uuid) to authenticated;

-- Personnes que l'utilisateur courant protège (il figure dans leurs proches).
create or replace function public.get_people_i_protect()
returns table (owner_id uuid, full_name text, phone text, avatar_url text, relation text)
language sql
stable
security definer
set search_path = ''
as $$
  select tc.owner_id, p.full_name, p.phone, p.avatar_url, tc.relation
  from public.trusted_contacts tc
  join public.profiles p on p.id = tc.owner_id
  where tc.contact_user_id = auth.uid()
  order by p.full_name;
$$;
grant execute on function public.get_people_i_protect() to authenticated;

-- Un proche peut se retirer de la liste d'une personne (consentement).
create or replace function public.leave_trusted_contact(p_owner_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  n int;
begin
  delete from public.trusted_contacts where owner_id = p_owner_id and contact_user_id = auth.uid();
  get diagnostics n = row_count;
  return n > 0;
end;
$$;
grant execute on function public.leave_trusted_contact(uuid) to authenticated;
