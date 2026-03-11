alter table public.servers
add column if not exists avatar_path text;

create or replace function public.server_id_from_storage_path(path text)
returns uuid
language sql
stable
as $$
  select nullif(split_part(path, '/', 1), '')::uuid;
$$;

insert into storage.buckets (id, name, public)
values ('server-assets', 'server-assets', true)
on conflict (id) do nothing;

drop policy if exists "server_assets_select_authenticated" on storage.objects;
create policy "server_assets_select_authenticated"
on storage.objects
for select
to authenticated
using (bucket_id = 'server-assets');

drop policy if exists "server_assets_insert_owner" on storage.objects;
create policy "server_assets_insert_owner"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'server-assets'
  and public.is_server_owner(public.server_id_from_storage_path(name))
);

drop policy if exists "server_assets_update_owner" on storage.objects;
create policy "server_assets_update_owner"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'server-assets'
  and public.is_server_owner(public.server_id_from_storage_path(name))
)
with check (
  bucket_id = 'server-assets'
  and public.is_server_owner(public.server_id_from_storage_path(name))
);

drop policy if exists "server_assets_delete_owner" on storage.objects;
create policy "server_assets_delete_owner"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'server-assets'
  and public.is_server_owner(public.server_id_from_storage_path(name))
);
