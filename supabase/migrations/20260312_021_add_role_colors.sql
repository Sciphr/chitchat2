alter table if exists public.server_roles
  add column if not exists color_hex text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'server_roles_color_hex_format'
  ) then
    alter table public.server_roles
      add constraint server_roles_color_hex_format
      check (color_hex is null or color_hex ~ '^#[0-9A-Fa-f]{6}$');
  end if;
end;
$$;

update public.server_roles
set color_hex = case lower(name)
  when 'owner' then '#F5B85A'
  when 'admin' then '#7DD3FC'
  when 'member' then '#C6CBD5'
  else color_hex
end
where color_hex is null
  and lower(name) in ('owner', 'admin', 'member');

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
      color_hex,
      permissions,
      is_system
    )
    values (
      server_id_input,
      'Member',
      '#C6CBD5',
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
    set
      is_system = true,
      color_hex = coalesce(color_hex, '#C6CBD5')
    where id = member_role_id
      and (
        is_system is distinct from true
        or color_hex is null
      );
  end if;

  insert into public.server_member_roles (server_id, user_id, role_id)
  values (server_id_input, user_id_input, member_role_id)
  on conflict do nothing;
end;
$$;
