alter table if exists public.servers
  add column if not exists description text not null default '',
  add column if not exists is_public boolean not null default false;

create table if not exists public.server_join_requests (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  user_id uuid not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default timezone('utc', now()),
  unique (server_id, user_id)
);

create index if not exists server_join_requests_server_status_idx
on public.server_join_requests (server_id, status, created_at);

create index if not exists server_join_requests_user_idx
on public.server_join_requests (user_id, created_at desc);

alter table public.server_join_requests enable row level security;

create or replace function public.can_review_server_join_requests(
  server_id_input uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select
    exists (
      select 1
      from public.servers
      where id = server_id_input
        and owner_id = auth.uid()
    )
    or exists (
      select 1
      from public.server_member_roles smr
      join public.server_roles sr
        on sr.id = smr.role_id
      where smr.server_id = server_id_input
        and smr.user_id = auth.uid()
        and (
          coalesce((sr.permissions ->> 'invite_members')::boolean, false)
          or coalesce((sr.permissions ->> 'manage_server')::boolean, false)
        )
    );
$$;

create or replace function public.list_joinable_servers(
  search_query_input text default ''
)
returns table (
  id uuid,
  name text,
  description text,
  avatar_path text,
  is_public boolean,
  member_count integer,
  is_member boolean,
  has_pending_request boolean,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with normalized as (
    select lower(trim(coalesce(search_query_input, ''))) as query
  ),
  member_counts as (
    select server_id, count(*)::integer as member_count
    from public.server_members
    group by server_id
  )
  select
    s.id,
    s.name,
    s.description,
    s.avatar_path,
    s.is_public,
    coalesce(mc.member_count, 0) as member_count,
    exists (
      select 1
      from public.server_members sm
      where sm.server_id = s.id
        and sm.user_id = auth.uid()
    ) as is_member,
    exists (
      select 1
      from public.server_join_requests sjr
      where sjr.server_id = s.id
        and sjr.user_id = auth.uid()
        and sjr.status = 'pending'
    ) as has_pending_request,
    s.created_at
  from public.servers s
  left join member_counts mc
    on mc.server_id = s.id
  cross join normalized n
  where n.query = ''
    or lower(s.name) like '%' || n.query || '%'
    or lower(s.description) like '%' || n.query || '%'
  order by
    coalesce(mc.member_count, 0) desc,
    s.name asc,
    s.created_at asc;
$$;

create or replace function public.join_public_server(
  server_id_input uuid
)
returns public.servers
language plpgsql
security definer
set search_path = public
as $$
declare
  target_server public.servers%rowtype;
begin
  select *
  into target_server
  from public.servers
  where id = server_id_input
    and is_public = true;

  if not found then
    raise exception 'Public server not found.';
  end if;

  insert into public.server_members (server_id, user_id)
  values (target_server.id, auth.uid())
  on conflict do nothing;

  update public.server_join_requests
  set
    status = 'approved',
    reviewed_by = auth.uid(),
    reviewed_at = timezone('utc', now())
  where server_id = target_server.id
    and user_id = auth.uid()
    and status = 'pending';

  return target_server;
end;
$$;

create or replace function public.request_server_join(
  server_id_input uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  target_server public.servers%rowtype;
begin
  select *
  into target_server
  from public.servers
  where id = server_id_input;

  if not found then
    raise exception 'Server not found.';
  end if;

  if exists (
    select 1
    from public.server_members
    where server_id = target_server.id
      and user_id = auth.uid()
  ) then
    return;
  end if;

  insert into public.server_join_requests (
    server_id,
    user_id,
    status,
    reviewed_by,
    reviewed_at
  )
  values (
    target_server.id,
    auth.uid(),
    'pending',
    null,
    null
  )
  on conflict (server_id, user_id)
  do update set
    status = 'pending',
    reviewed_by = null,
    reviewed_at = null,
    created_at = timezone('utc', now());
end;
$$;

create or replace function public.list_server_join_requests(
  server_id_input uuid
)
returns table (
  id uuid,
  server_id uuid,
  user_id uuid,
  display_name text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select
    sjr.id,
    sjr.server_id,
    sjr.user_id,
    coalesce(up.display_name, 'Unknown') as display_name,
    sjr.created_at
  from public.server_join_requests sjr
  left join public.user_profiles up
    on up.id = sjr.user_id
  where sjr.server_id = server_id_input
    and sjr.status = 'pending'
    and public.can_review_server_join_requests(server_id_input)
  order by sjr.created_at asc;
$$;

create or replace function public.decide_server_join_request(
  request_id_input uuid,
  approve_input boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  request_row public.server_join_requests%rowtype;
begin
  select *
  into request_row
  from public.server_join_requests
  where id = request_id_input;

  if not found then
    raise exception 'Join request not found.';
  end if;

  if not public.can_review_server_join_requests(request_row.server_id) then
    raise exception 'You do not have permission to review join requests.';
  end if;

  if approve_input then
    insert into public.server_members (server_id, user_id)
    values (request_row.server_id, request_row.user_id)
    on conflict do nothing;
  end if;

  update public.server_join_requests
  set
    status = case when approve_input then 'approved' else 'rejected' end,
    reviewed_by = auth.uid(),
    reviewed_at = timezone('utc', now())
  where id = request_id_input;
end;
$$;

create or replace function public.update_server_discovery_settings(
  server_id_input uuid,
  is_public_input boolean,
  description_input text default ''
)
returns public.servers
language plpgsql
security definer
set search_path = public
as $$
declare
  target_server public.servers%rowtype;
begin
  if not (
    exists (
      select 1
      from public.servers
      where id = server_id_input
        and owner_id = auth.uid()
    )
    or exists (
      select 1
      from public.server_member_roles smr
      join public.server_roles sr
        on sr.id = smr.role_id
      where smr.server_id = server_id_input
        and smr.user_id = auth.uid()
        and coalesce((sr.permissions ->> 'manage_server')::boolean, false)
    )
  ) then
    raise exception 'You do not have permission to edit this server.';
  end if;

  update public.servers
  set
    is_public = is_public_input,
    description = trim(coalesce(description_input, ''))
  where id = server_id_input
  returning *
  into target_server;

  return target_server;
end;
$$;

drop policy if exists "server_join_requests_select_self_or_reviewer" on public.server_join_requests;
create policy "server_join_requests_select_self_or_reviewer"
on public.server_join_requests
for select
to authenticated
using (
  user_id = auth.uid()
  or public.can_review_server_join_requests(server_id)
);

drop policy if exists "server_join_requests_insert_self" on public.server_join_requests;
create policy "server_join_requests_insert_self"
on public.server_join_requests
for insert
to authenticated
with check (
  user_id = auth.uid()
  and status = 'pending'
);

drop policy if exists "server_join_requests_update_reviewer" on public.server_join_requests;
create policy "server_join_requests_update_reviewer"
on public.server_join_requests
for update
to authenticated
using (
  public.can_review_server_join_requests(server_id)
)
with check (
  public.can_review_server_join_requests(server_id)
);

grant execute on function public.list_joinable_servers(text) to authenticated;
grant execute on function public.join_public_server(uuid) to authenticated;
grant execute on function public.request_server_join(uuid) to authenticated;
grant execute on function public.list_server_join_requests(uuid) to authenticated;
grant execute on function public.decide_server_join_request(uuid, boolean) to authenticated;
grant execute on function public.update_server_discovery_settings(uuid, boolean, text) to authenticated;
