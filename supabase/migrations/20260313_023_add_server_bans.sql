-- Server bans: ban_members permission, server_bans table, helpers.

-- 1. Add ban_members to the permissions check in existing role functions.
--    The permission key is 'ban_members'.

-- 2. Create server_bans table.
create table if not exists public.server_bans (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  user_id uuid not null,
  banned_by uuid not null,
  reason text,
  created_at timestamptz not null default timezone('utc', now()),
  unique (server_id, user_id)
);

create index if not exists server_bans_server_idx
  on public.server_bans (server_id, created_at desc);

alter table public.server_bans enable row level security;

-- 3. RLS policies for server_bans.
-- (has_server_permission already exists in the DB — no redefinition needed.)

-- Server owners / users with ban_members can select bans for their server.
create policy "Ban list visible to members with ban_members"
  on public.server_bans
  for select
  using (
    public.has_server_permission(server_id, 'ban_members')
    or exists (
      select 1 from public.servers
      where id = server_id and owner_id = auth.uid()
    )
  );

-- Only via RPC functions (security definer) — no direct insert/delete allowed.
create policy "No direct ban insert"
  on public.server_bans
  for insert
  with check (false);

create policy "No direct ban delete"
  on public.server_bans
  for delete
  using (false);

-- 5. ban_member RPC.
create or replace function public.ban_server_member(
  server_id_input uuid,
  user_id_input uuid,
  reason_input text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  -- Must have ban_members permission or be owner.
  if not public.has_server_permission(server_id_input, 'ban_members') then
    raise exception 'You do not have permission to ban members.';
  end if;

  -- Cannot ban the server owner.
  if exists (
    select 1 from public.servers
    where id = server_id_input and owner_id = user_id_input
  ) then
    raise exception 'Cannot ban the server owner.';
  end if;

  -- Cannot ban yourself.
  if user_id_input = current_user_id then
    raise exception 'Cannot ban yourself.';
  end if;

  -- Insert ban.
  insert into public.server_bans (server_id, user_id, banned_by, reason)
  values (server_id_input, user_id_input, current_user_id, reason_input)
  on conflict (server_id, user_id) do update
    set reason = excluded.reason,
        banned_by = excluded.banned_by,
        created_at = timezone('utc', now());

  -- Remove from server.
  delete from public.server_members
  where server_id = server_id_input and user_id = user_id_input;
end;
$$;

grant execute on function public.ban_server_member(uuid, uuid, text)
to authenticated;

-- 6. unban_member RPC.
create or replace function public.unban_server_member(
  server_id_input uuid,
  user_id_input uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
begin
  if current_user_id is null then
    raise exception 'You must be signed in.';
  end if;

  if not public.has_server_permission(server_id_input, 'ban_members') then
    raise exception 'You do not have permission to unban members.';
  end if;

  delete from public.server_bans
  where server_id = server_id_input and user_id = user_id_input;
end;
$$;

grant execute on function public.unban_server_member(uuid, uuid)
to authenticated;

-- 7. list_server_bans RPC.
create or replace function public.list_server_bans(
  server_id_input uuid
)
returns table (
  id uuid,
  server_id uuid,
  user_id uuid,
  banned_by uuid,
  reason text,
  display_name text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    sb.id,
    sb.server_id,
    sb.user_id,
    sb.banned_by,
    sb.reason,
    coalesce(up.display_name, 'Unknown') as display_name,
    sb.created_at
  from public.server_bans sb
  left join public.user_profiles up on up.id = sb.user_id
  where sb.server_id = server_id_input
    and public.has_server_permission(server_id_input, 'ban_members')
  order by sb.created_at desc;
$$;

grant execute on function public.list_server_bans(uuid)
to authenticated;

-- 8. Prevent banned users from joining via invite or public join.
--    Re-create join_server_by_invite and join_public_server with ban check.
drop function if exists public.join_server_by_invite(text);
create or replace function public.join_server_by_invite(
  invite_code_input text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  server_row public.servers%rowtype;
begin
  if current_user_id is null then
    raise exception 'You must be signed in to join a server.';
  end if;

  select * into server_row
  from public.servers
  where invite_code = upper(trim(invite_code_input))
  limit 1;

  if server_row.id is null then
    raise exception 'Invalid invite code.';
  end if;

  -- Ban check.
  if exists (
    select 1 from public.server_bans
    where server_id = server_row.id and user_id = current_user_id
  ) then
    raise exception 'You are banned from this server.';
  end if;

  insert into public.server_members (server_id, user_id)
  values (server_row.id, current_user_id)
  on conflict do nothing;

  perform public.ensure_server_member_role(server_row.id, current_user_id);

  return row_to_json(server_row);
end;
$$;

grant execute on function public.join_server_by_invite(text)
to authenticated;

drop function if exists public.join_public_server(uuid);
create or replace function public.join_public_server(
  server_id_input uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  server_row public.servers%rowtype;
begin
  if current_user_id is null then
    raise exception 'You must be signed in to join a server.';
  end if;

  select * into server_row
  from public.servers
  where id = server_id_input and is_public = true
  limit 1;

  if server_row.id is null then
    raise exception 'Server not found or is not public.';
  end if;

  -- Ban check.
  if exists (
    select 1 from public.server_bans
    where server_id = server_row.id and user_id = current_user_id
  ) then
    raise exception 'You are banned from this server.';
  end if;

  insert into public.server_members (server_id, user_id)
  values (server_row.id, current_user_id)
  on conflict do nothing;

  perform public.ensure_server_member_role(server_row.id, current_user_id);

  return row_to_json(server_row);
end;
$$;

grant execute on function public.join_public_server(uuid)
to authenticated;
