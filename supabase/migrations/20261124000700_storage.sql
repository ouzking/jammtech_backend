-- =============================================================================
-- Stockage : avatars et enregistrements (buckets privés)
-- =============================================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  -- Avatars : l'app redimensionne à 600 px max avant l'envoi ; 1 Mo max.
  ('avatars', 'avatars', false, 1048576, array['image/jpeg', 'image/png', 'image/webp']),
  -- Vidéos : accès uniquement par URL signée de courte durée. Écriture par
  -- les Edge Functions (URL d'upload signée remise à l'appareil).
  ('recordings', 'recordings', false, 209715200, array['video/mp4', 'image/jpeg', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Avatars : chemin `<user_id>/<fichier>`. Écriture uniquement dans son dossier.
create policy avatars_insert_own on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_update_own on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_delete_own on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
-- Lecture : soi-même, ses proches, et les personnes qu'on protège.
-- SECURITY DEFINER : la RLS de trusted_contacts ne montre au proche que ses
-- propres listes, il faut donc vérifier la relation dans les deux sens ici.
create or replace function private.can_view_avatar(p_folder text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_folder = auth.uid()::text
      or exists (
        select 1 from public.trusted_contacts tc
        where (tc.owner_id::text = p_folder and tc.contact_user_id = auth.uid())
           or (tc.contact_user_id::text = p_folder and tc.owner_id = auth.uid())
      );
$$;
grant execute on function private.can_view_avatar(text) to authenticated;

create policy avatars_select_related on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and private.can_view_avatar((storage.foldername(name))[1]));

-- Enregistrements : chemin `<home_id>/<recording_id>.mp4`. Lecture (donc
-- création d'URL signée) par les membres de la maison tant que la ligne
-- `recordings` existe. Aucune écriture côté client.
create policy recordings_select_member on storage.objects
  for select to authenticated
  using (
    bucket_id = 'recordings'
    and exists (
      select 1 from public.recordings r
      where (r.storage_path = name or r.thumbnail_path = name)
        and private.is_home_member(r.home_id)
    )
  );
