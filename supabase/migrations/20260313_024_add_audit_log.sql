-- Server audit log: tracks moderation and administrative actions.

create table if not exists public.server_audit_log (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  actor_id uuid not null,
  target_user_id uuid,
  action text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists server_audit_log_server_idx
  on public.server_audit_log (server_id, created_at desc);

create index if not exists server_audit_log_action_idx
  on public.server_audit_log (server_id, action, created_at desc);

alter table public.server_audit_log enable row level security;

-- Only members with manage_server can view the audit log.
create policy "Audit log visible to manage_server members"
  on public.server_audit_log
  for select
  using (
    public.has_server_permission(server_id, 'manage_server')
  );

-- No direct insert/delete (all writes go through security-definer functions).
create policy "No direct audit log insert"
  on public.server_audit_log
  for insert
  with check (false);

-- Helper to insert an audit log entry (called from other security-definer functions).
create or replace function public.audit_log_insert(
  server_id_input uuid,
  actor_id_input uuid,
  action_input text,
  details_input jsonb default '{}'::jsonb,
  target_user_id_input uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.server_audit_log (
    server_id, actor_id, target_user_id, action, details
  ) values (
    server_id_input,
    actor_id_input,
    target_user_id_input,
    action_input,
    details_input
  );
end;
$$;

-- list_server_audit_log RPC (permission-gated, filterable by action).
create or replace function public.list_server_audit_log(
  server_id_input uuid,
  action_filter text default null,
  page_size int default 50,
  before_id uuid default null
)
returns table (
  id uuid,
  server_id uuid,
  actor_id uuid,
  actor_display_name text,
  target_user_id uuid,
  target_display_name text,
  action text,
  details jsonb,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.has_server_permission(server_id_input, 'manage_server') then
    raise exception 'You do not have permission to view the audit log.';
  end if;

  return query
    select
      al.id,
      al.server_id,
      al.actor_id,
      coalesce(actor_profile.display_name, 'Unknown') as actor_display_name,
      al.target_user_id,
      coalesce(target_profile.display_name, null) as target_display_name,
      al.action,
      al.details,
      al.created_at
    from public.server_audit_log al
    left join public.user_profiles actor_profile on actor_profile.id = al.actor_id
    left join public.user_profiles target_profile on target_profile.id = al.target_user_id
    where al.server_id = server_id_input
      and (action_filter is null or al.action = action_filter)
      and (before_id is null or al.created_at < (
        select created_at from public.server_audit_log where id = before_id
      ))
    order by al.created_at desc
    limit page_size;
end;
$$;

grant execute on function public.list_server_audit_log(uuid, text, int, uuid)
to authenticated;

-- Wrap ban_server_member and unban_server_member to also write audit log.
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

  if not public.has_server_permission(server_id_input, 'ban_members') then
    raise exception 'You do not have permission to ban members.';
  end if;

  if exists (
    select 1 from public.servers
    where id = server_id_input and owner_id = user_id_input
  ) then
    raise exception 'Cannot ban the server owner.';
  end if;

  if user_id_input = current_user_id then
    raise exception 'Cannot ban yourself.';
  end if;

  insert into public.server_bans (server_id, user_id, banned_by, reason)
  values (server_id_input, user_id_input, current_user_id, reason_input)
  on conflict (server_id, user_id) do update
    set reason = excluded.reason,
        banned_by = excluded.banned_by,
        created_at = timezone('utc', now());

  delete from public.server_members
  where server_id = server_id_input and user_id = user_id_input;

  perform public.audit_log_insert(
    server_id_input,
    current_user_id,
    'member_banned',
    jsonb_build_object('reason', reason_input),
    user_id_input
  );
end;
$$;

grant execute on function public.ban_server_member(uuid, uuid, text)
to authenticated;

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

  perform public.audit_log_insert(
    server_id_input,
    current_user_id,
    'member_unbanned',
    '{}'::jsonb,
    user_id_input
  );
end;
$$;

grant execute on function public.unban_server_member(uuid, uuid)
to authenticated;

-- Kick also gets audit-logged; wrap removeMemberFromServer logic.
create or replace function public.kick_server_member(
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

  if not (
    public.has_server_permission(server_id_input, 'manage_server')
    or public.has_server_permission(server_id_input, 'ban_members')
    or exists (
      select 1 from public.servers
      where id = server_id_input and owner_id = current_user_id
    )
  ) then
    raise exception 'You do not have permission to kick members.';
  end if;

  if exists (
    select 1 from public.servers
    where id = server_id_input and owner_id = user_id_input
  ) then
    raise exception 'Cannot kick the server owner.';
  end if;

  if user_id_input = current_user_id then
    raise exception 'Cannot kick yourself.';
  end if;

  delete from public.server_members
  where server_id = server_id_input and user_id = user_id_input;

  perform public.audit_log_insert(
    server_id_input,
    current_user_id,
    'member_kicked',
    '{}'::jsonb,
    user_id_input
  );
end;
$$;

grant execute on function public.kick_server_member(uuid, uuid)
to authenticated;
