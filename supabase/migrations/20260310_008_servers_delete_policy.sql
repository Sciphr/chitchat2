drop policy if exists "servers_delete_owner" on public.servers;
create policy "servers_delete_owner"
on public.servers
for delete
to authenticated
using (owner_id = auth.uid());
