create table if not exists public.channel_permission_overrides (
  channel_id uuid not null references public.channels (id) on delete cascade,
  role_id uuid not null references public.server_roles (id) on delete cascade,
  allow_permissions jsonb not null default '{}'::jsonb,
  deny_permissions jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now()),
  primary key (channel_id, role_id)
);

create index if not exists channel_permission_overrides_role_idx
  on public.channel_permission_overrides (role_id, channel_id);

update public.server_roles
set permissions = permissions || jsonb_build_object('view_channel', true)
where not (permissions ? 'view_channel');

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
      'view_channel', true,
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
      'view_channel', true,
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
      'view_channel', true,
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

create or replace function public.has_channel_permission(
  target_channel uuid,
  permission_key text
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  with channel_info as (
    select c.server_id
    from public.channels c
    where c.id = target_channel
  ),
  assigned_role_ids as (
    select smr.role_id
    from channel_info ci
    join public.server_member_roles smr
      on smr.server_id = ci.server_id
    where smr.user_id = auth.uid()
  ),
  overrides as (
    select
      cpo.allow_permissions,
      cpo.deny_permissions
    from public.channel_permission_overrides cpo
    where cpo.channel_id = target_channel
      and cpo.role_id in (select role_id from assigned_role_ids)
  )
  select case
    when not exists (select 1 from channel_info) then false
    when public.is_server_owner((select server_id from channel_info limit 1)) then true
    when exists (
      select 1
      from overrides o
      where coalesce((o.deny_permissions ->> permission_key)::boolean, false)
    ) then false
    when exists (
      select 1
      from overrides o
      where coalesce((o.allow_permissions ->> permission_key)::boolean, false)
    ) then true
    else public.has_server_permission(
      (select server_id from channel_info limit 1),
      permission_key
    )
  end;
$$;

create or replace function public.voice_topic_kind(topic_name text)
returns text
language sql
stable
as $$
  select nullif(split_part(topic_name, ':', 2), '');
$$;

create or replace function public.voice_channel_id_from_topic(topic_name text)
returns uuid
language sql
stable
as $$
  select nullif(split_part(topic_name, ':', 3), '')::uuid;
$$;

create or replace function public.voice_target_user_id_from_topic(topic_name text)
returns uuid
language sql
stable
as $$
  select nullif(split_part(topic_name, ':', 4), '')::uuid;
$$;

alter table public.channel_permission_overrides enable row level security;

drop policy if exists "channel_permission_overrides_select_member" on public.channel_permission_overrides;
create policy "channel_permission_overrides_select_member"
on public.channel_permission_overrides
for select
to authenticated
using (
  public.is_server_member(public.channel_server_id(channel_id))
);

drop policy if exists "channel_permission_overrides_manage_channels" on public.channel_permission_overrides;
create policy "channel_permission_overrides_manage_channels"
on public.channel_permission_overrides
for all
to authenticated
using (
  public.has_server_permission(
    public.channel_server_id(channel_id),
    'manage_channels'
  )
)
with check (
  public.has_server_permission(
    public.channel_server_id(channel_id),
    'manage_channels'
  )
);

drop policy if exists "channels_select_member" on public.channels;
create policy "channels_select_member"
on public.channels
for select
to authenticated
using (
  public.is_server_member(server_id)
  and public.has_channel_permission(id, 'view_channel')
);

drop policy if exists "channel_messages_select_member" on public.channel_messages;
create policy "channel_messages_select_member"
on public.channel_messages
for select
to authenticated
using (
  public.channel_kind_of(channel_id) = 'text'
  and public.has_channel_permission(channel_id, 'view_channel')
);

drop policy if exists "channel_messages_insert_member" on public.channel_messages;
create policy "channel_messages_insert_member"
on public.channel_messages
for insert
to authenticated
with check (
  auth.uid() = sender_id
  and public.channel_kind_of(channel_id) = 'text'
  and public.has_channel_permission(channel_id, 'view_channel')
  and public.has_channel_permission(channel_id, 'send_messages')
);

drop policy if exists "realtime_voice_channel_select_member" on realtime.messages;
create policy "realtime_voice_channel_select_member"
on realtime.messages
for select
to authenticated
using (
  realtime.messages.extension in ('broadcast', 'presence')
  and public.voice_topic_kind(realtime.topic()) in ('presence', 'base', 'camera', 'screen')
  and public.has_channel_permission(
    public.voice_channel_id_from_topic(realtime.topic()),
    'view_channel'
  )
  and public.has_channel_permission(
    public.voice_channel_id_from_topic(realtime.topic()),
    'join_voice'
  )
  and (
    public.voice_topic_kind(realtime.topic()) = 'presence'
    or public.voice_target_user_id_from_topic(realtime.topic()) = auth.uid()
  )
);

drop policy if exists "realtime_voice_channel_insert_member" on realtime.messages;

drop policy if exists "realtime_voice_presence_insert_member" on realtime.messages;
create policy "realtime_voice_presence_insert_member"
on realtime.messages
for insert
to authenticated
with check (
  realtime.messages.extension = 'presence'
  and public.voice_topic_kind(realtime.topic()) = 'presence'
  and public.has_channel_permission(
    public.voice_channel_id_from_topic(realtime.topic()),
    'view_channel'
  )
  and public.has_channel_permission(
    public.voice_channel_id_from_topic(realtime.topic()),
    'join_voice'
  )
);

drop policy if exists "realtime_voice_base_broadcast_insert_member" on realtime.messages;
create policy "realtime_voice_base_broadcast_insert_member"
on realtime.messages
for insert
to authenticated
with check (
  realtime.messages.extension = 'broadcast'
  and public.voice_topic_kind(realtime.topic()) = 'base'
  and public.has_channel_permission(
    public.voice_channel_id_from_topic(realtime.topic()),
    'view_channel'
  )
  and public.has_channel_permission(
    public.voice_channel_id_from_topic(realtime.topic()),
    'join_voice'
  )
);

drop policy if exists "realtime_voice_camera_broadcast_insert_member" on realtime.messages;
create policy "realtime_voice_camera_broadcast_insert_member"
on realtime.messages
for insert
to authenticated
with check (
  realtime.messages.extension = 'broadcast'
  and public.voice_topic_kind(realtime.topic()) = 'camera'
  and public.has_channel_permission(
    public.voice_channel_id_from_topic(realtime.topic()),
    'view_channel'
  )
  and public.has_channel_permission(
    public.voice_channel_id_from_topic(realtime.topic()),
    'join_voice'
  )
  and public.has_channel_permission(
    public.voice_channel_id_from_topic(realtime.topic()),
    'stream_camera'
  )
);

drop policy if exists "realtime_voice_screen_broadcast_insert_member" on realtime.messages;
create policy "realtime_voice_screen_broadcast_insert_member"
on realtime.messages
for insert
to authenticated
with check (
  realtime.messages.extension = 'broadcast'
  and public.voice_topic_kind(realtime.topic()) = 'screen'
  and public.has_channel_permission(
    public.voice_channel_id_from_topic(realtime.topic()),
    'view_channel'
  )
  and public.has_channel_permission(
    public.voice_channel_id_from_topic(realtime.topic()),
    'join_voice'
  )
  and public.has_channel_permission(
    public.voice_channel_id_from_topic(realtime.topic()),
    'share_screen'
  )
);
