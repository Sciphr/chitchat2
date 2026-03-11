create or replace function public.has_server_permission(
  target_server uuid,
  permission_key text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    public.is_server_owner(target_server)
    or exists (
      select 1
      from public.server_member_roles smr
      join public.server_roles sr
        on sr.id = smr.role_id
      where smr.server_id = target_server
        and smr.user_id = auth.uid()
        and coalesce((sr.permissions ->> permission_key)::boolean, false)
    );
$$;

create or replace function public.join_server_by_invite(invite_code_input text)
returns public.servers
language plpgsql
security definer
set search_path = public
as $$
declare
  target_server public.servers;
begin
  select *
  into target_server
  from public.servers
  where invite_code = upper(trim(invite_code_input))
  limit 1;

  if target_server.id is null then
    raise exception 'Invite code not found.';
  end if;

  insert into public.server_members (server_id, user_id)
  values (target_server.id, auth.uid())
  on conflict do nothing;

  insert into public.server_member_roles (server_id, user_id, role_id)
  select target_server.id, auth.uid(), sr.id
  from public.server_roles sr
  where sr.server_id = target_server.id
    and sr.is_system = true
    and sr.name = 'Member'
  on conflict do nothing;

  return target_server;
end;
$$;

drop policy if exists "servers_select_member" on public.servers;
create policy "servers_select_member"
on public.servers
for select
to authenticated
using (public.is_server_member(id) or owner_id = auth.uid());

drop policy if exists "servers_update_owner" on public.servers;
drop policy if exists "servers_update_manage_server" on public.servers;
create policy "servers_update_manage_server"
on public.servers
for update
to authenticated
using (public.has_server_permission(id, 'manage_server'))
with check (public.has_server_permission(id, 'manage_server'));

drop policy if exists "server_members_insert_owner_membership" on public.server_members;
create policy "server_members_insert_owner_membership"
on public.server_members
for insert
to authenticated
with check (
  auth.uid() = user_id
  and public.is_server_owner(server_id)
);

drop policy if exists "server_roles_manage_owner" on public.server_roles;
drop policy if exists "server_roles_manage_roles" on public.server_roles;
create policy "server_roles_manage_roles"
on public.server_roles
for all
to authenticated
using (public.has_server_permission(server_id, 'manage_roles'))
with check (public.has_server_permission(server_id, 'manage_roles'));

drop policy if exists "server_member_roles_manage_owner" on public.server_member_roles;
drop policy if exists "server_member_roles_manage_roles" on public.server_member_roles;
create policy "server_member_roles_manage_roles"
on public.server_member_roles
for all
to authenticated
using (public.has_server_permission(server_id, 'manage_roles'))
with check (public.has_server_permission(server_id, 'manage_roles'));

drop policy if exists "channels_insert_owner" on public.channels;
drop policy if exists "channels_insert_manage_channels" on public.channels;
create policy "channels_insert_manage_channels"
on public.channels
for insert
to authenticated
with check (
  auth.uid() = created_by
  and public.has_server_permission(server_id, 'manage_channels')
);

drop policy if exists "channels_update_owner" on public.channels;
drop policy if exists "channels_update_manage_channels" on public.channels;
create policy "channels_update_manage_channels"
on public.channels
for update
to authenticated
using (public.has_server_permission(server_id, 'manage_channels'))
with check (public.has_server_permission(server_id, 'manage_channels'));

drop policy if exists "channels_delete_owner" on public.channels;
drop policy if exists "channels_delete_manage_channels" on public.channels;
create policy "channels_delete_manage_channels"
on public.channels
for delete
to authenticated
using (public.has_server_permission(server_id, 'manage_channels'));
