create extension if not exists "pgcrypto";

do $$
begin
  create type public.channel_kind as enum ('text', 'voice');
exception
  when duplicate_object then null;
end
$$;

create table if not exists public.servers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 80),
  owner_id uuid not null references auth.users (id) on delete cascade,
  invite_code text not null unique default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)),
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.server_members (
  server_id uuid not null references public.servers (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  joined_at timestamptz not null default timezone('utc', now()),
  primary key (server_id, user_id)
);

create table if not exists public.server_roles (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers (id) on delete cascade,
  name text not null,
  permissions jsonb not null default '{}'::jsonb,
  is_system bool not null default false,
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.server_member_roles (
  server_id uuid not null,
  user_id uuid not null,
  role_id uuid not null references public.server_roles (id) on delete cascade,
  primary key (server_id, user_id, role_id),
  foreign key (server_id, user_id)
    references public.server_members (server_id, user_id)
    on delete cascade
);

create table if not exists public.channels (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers (id) on delete cascade,
  name text not null check (char_length(trim(name)) between 1 and 80),
  kind public.channel_kind not null,
  position int not null default 0,
  created_by uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.channel_messages (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.channels (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  sender_display_name text not null check (char_length(trim(sender_display_name)) between 1 and 80),
  body text not null check (char_length(trim(body)) between 1 and 4000),
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists server_members_user_id_idx
  on public.server_members (user_id, server_id);

create index if not exists channels_server_position_idx
  on public.channels (server_id, position, created_at);

create index if not exists channel_messages_channel_created_at_idx
  on public.channel_messages (channel_id, created_at);

do $$
begin
  alter publication supabase_realtime add table public.channel_messages;
exception
  when duplicate_object then null;
end
$$;

create or replace function public.is_server_member(target_server uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.server_members sm
    where sm.server_id = target_server
      and sm.user_id = auth.uid()
  );
$$;

create or replace function public.is_server_owner(target_server uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.servers s
    where s.id = target_server
      and s.owner_id = auth.uid()
  );
$$;

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

create or replace function public.channel_server_id(target_channel uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select c.server_id
  from public.channels c
  where c.id = target_channel;
$$;

create or replace function public.channel_kind_of(target_channel uuid)
returns public.channel_kind
language sql
stable
security definer
set search_path = public
as $$
  select c.kind
  from public.channels c
  where c.id = target_channel;
$$;

create or replace function public.voice_channel_id_from_topic(topic_name text)
returns uuid
language sql
stable
as $$
  select nullif(split_part(topic_name, ':', 2), '')::uuid;
$$;

create or replace function public.handle_server_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  owner_role_id uuid;
  admin_role_id uuid;
  member_role_id uuid;
begin
  insert into public.server_members (server_id, user_id)
  values (new.id, new.owner_id)
  on conflict do nothing;

  insert into public.server_roles (server_id, name, permissions, is_system)
  values (
    new.id,
    'Owner',
    jsonb_build_object(
      'manage_server', true,
      'manage_roles', true,
      'manage_channels', true,
      'invite_members', true,
      'send_messages', true,
      'join_voice', true,
      'stream_camera', true,
      'share_screen', true
    ),
    true
  )
  returning id into owner_role_id;

  insert into public.server_roles (server_id, name, permissions, is_system)
  values (
    new.id,
    'Admin',
    jsonb_build_object(
      'manage_channels', true,
      'invite_members', true,
      'send_messages', true,
      'join_voice', true,
      'stream_camera', true,
      'share_screen', true
    ),
    true
  )
  returning id into admin_role_id;

  insert into public.server_roles (server_id, name, permissions, is_system)
  values (
    new.id,
    'Member',
    jsonb_build_object(
      'send_messages', true,
      'join_voice', true,
      'stream_camera', true,
      'share_screen', true
    ),
    true
  )
  returning id into member_role_id;

  insert into public.server_member_roles (server_id, user_id, role_id)
  values
    (new.id, new.owner_id, owner_role_id),
    (new.id, new.owner_id, admin_role_id),
    (new.id, new.owner_id, member_role_id)
  on conflict do nothing;

  insert into public.channels (server_id, name, kind, position, created_by)
  values
    (new.id, 'general', 'text', 0, new.owner_id),
    (new.id, 'lounge', 'voice', 1, new.owner_id);

  return new;
end;
$$;

drop trigger if exists on_server_created on public.servers;

create trigger on_server_created
after insert on public.servers
for each row execute function public.handle_server_created();

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

alter table public.servers enable row level security;
alter table public.server_members enable row level security;
alter table public.server_roles enable row level security;
alter table public.server_member_roles enable row level security;
alter table public.channels enable row level security;
alter table public.channel_messages enable row level security;

drop policy if exists "servers_select_member" on public.servers;
create policy "servers_select_member"
on public.servers
for select
to authenticated
using (public.is_server_member(id) or owner_id = auth.uid());

drop policy if exists "servers_insert_owner" on public.servers;
create policy "servers_insert_owner"
on public.servers
for insert
to authenticated
with check (auth.uid() = owner_id);

drop policy if exists "servers_update_owner" on public.servers;
drop policy if exists "servers_update_manage_server" on public.servers;
create policy "servers_update_manage_server"
on public.servers
for update
to authenticated
using (public.has_server_permission(id, 'manage_server'))
with check (public.has_server_permission(id, 'manage_server'));

drop policy if exists "server_members_select_member" on public.server_members;
create policy "server_members_select_member"
on public.server_members
for select
to authenticated
using (public.is_server_member(server_id));

drop policy if exists "server_members_insert_owner_membership" on public.server_members;
create policy "server_members_insert_owner_membership"
on public.server_members
for insert
to authenticated
with check (
  auth.uid() = user_id
  and public.is_server_owner(server_id)
);

drop policy if exists "server_members_delete_self_or_owner" on public.server_members;
create policy "server_members_delete_self_or_owner"
on public.server_members
for delete
to authenticated
using (auth.uid() = user_id or public.is_server_owner(server_id));

drop policy if exists "server_roles_select_member" on public.server_roles;
create policy "server_roles_select_member"
on public.server_roles
for select
to authenticated
using (public.is_server_member(server_id));

drop policy if exists "server_roles_manage_owner" on public.server_roles;
drop policy if exists "server_roles_manage_roles" on public.server_roles;
create policy "server_roles_manage_roles"
on public.server_roles
for all
to authenticated
using (public.has_server_permission(server_id, 'manage_roles'))
with check (public.has_server_permission(server_id, 'manage_roles'));

drop policy if exists "server_member_roles_select_member" on public.server_member_roles;
create policy "server_member_roles_select_member"
on public.server_member_roles
for select
to authenticated
using (public.is_server_member(server_id));

drop policy if exists "server_member_roles_manage_owner" on public.server_member_roles;
drop policy if exists "server_member_roles_manage_roles" on public.server_member_roles;
create policy "server_member_roles_manage_roles"
on public.server_member_roles
for all
to authenticated
using (public.has_server_permission(server_id, 'manage_roles'))
with check (public.has_server_permission(server_id, 'manage_roles'));

drop policy if exists "channels_select_member" on public.channels;
create policy "channels_select_member"
on public.channels
for select
to authenticated
using (public.is_server_member(server_id));

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

drop policy if exists "channel_messages_select_member" on public.channel_messages;
create policy "channel_messages_select_member"
on public.channel_messages
for select
to authenticated
using (
  public.is_server_member(public.channel_server_id(channel_id))
  and public.channel_kind_of(channel_id) = 'text'
);

drop policy if exists "channel_messages_insert_member" on public.channel_messages;
create policy "channel_messages_insert_member"
on public.channel_messages
for insert
to authenticated
with check (
  auth.uid() = sender_id
  and public.is_server_member(public.channel_server_id(channel_id))
  and public.channel_kind_of(channel_id) = 'text'
);

alter table realtime.messages enable row level security;

drop policy if exists "realtime_voice_channel_select_member" on realtime.messages;
create policy "realtime_voice_channel_select_member"
on realtime.messages
for select
to authenticated
using (
  realtime.messages.extension in ('broadcast', 'presence')
  and public.is_server_member(
    public.channel_server_id(public.voice_channel_id_from_topic(realtime.topic()))
  )
  and public.channel_kind_of(public.voice_channel_id_from_topic(realtime.topic())) = 'voice'
);

drop policy if exists "realtime_voice_channel_insert_member" on realtime.messages;
create policy "realtime_voice_channel_insert_member"
on realtime.messages
for insert
to authenticated
with check (
  realtime.messages.extension in ('broadcast', 'presence')
  and public.is_server_member(
    public.channel_server_id(public.voice_channel_id_from_topic(realtime.topic()))
  )
  and public.channel_kind_of(public.voice_channel_id_from_topic(realtime.topic())) = 'voice'
);
