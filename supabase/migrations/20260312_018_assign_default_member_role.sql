create or replace function public.ensure_server_member_role(
  server_id_input uuid,
  user_id_input uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  member_role_id uuid;
begin
  select sr.id
  into member_role_id
  from public.server_roles sr
  where sr.server_id = server_id_input
    and lower(sr.name) = 'member'
  order by sr.is_system desc, sr.created_at asc
  limit 1;

  if member_role_id is null then
    insert into public.server_roles (
      server_id,
      name,
      permissions,
      is_system
    )
    values (
      server_id_input,
      'Member',
      jsonb_build_object(
        'view_channel', true,
        'manage_server', false,
        'manage_roles', false,
        'manage_channels', false,
        'manage_messages', false,
        'invite_members', false,
        'send_messages', true,
        'join_voice', true,
        'stream_camera', true,
        'share_screen', true
      ),
      true
    )
    returning id into member_role_id;
  else
    update public.server_roles
    set is_system = true
    where id = member_role_id
      and is_system is distinct from true;
  end if;

  insert into public.server_member_roles (server_id, user_id, role_id)
  values (server_id_input, user_id_input, member_role_id)
  on conflict do nothing;
end;
$$;

create or replace function public.assign_default_server_member_role()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.ensure_server_member_role(new.server_id, new.user_id);
  return new;
end;
$$;

drop trigger if exists assign_default_server_member_role on public.server_members;

create trigger assign_default_server_member_role
after insert on public.server_members
for each row
execute function public.assign_default_server_member_role();

do $$
declare
  membership record;
begin
  for membership in
    select server_id, user_id
    from public.server_members
  loop
    perform public.ensure_server_member_role(
      membership.server_id,
      membership.user_id
    );
  end loop;
end;
$$;
