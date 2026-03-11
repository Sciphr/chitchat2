drop policy if exists "realtime_server_presence_insert_member" on realtime.messages;

create policy "realtime_server_presence_insert_member"
on realtime.messages
for insert
to authenticated
with check (
  realtime.messages.extension = 'presence'
  and split_part((select realtime.topic()), ':', 1) = 'server'
  and split_part((select realtime.topic()), ':', 2) = 'presence'
  and nullif(split_part((select realtime.topic()), ':', 3), '') is not null
  and (
    exists (
      select 1
      from public.server_members
      where server_members.server_id::text = split_part((select realtime.topic()), ':', 3)
        and server_members.user_id = (select auth.uid())
    )
    or exists (
      select 1
      from public.servers
      where servers.id::text = split_part((select realtime.topic()), ':', 3)
        and servers.owner_id = (select auth.uid())
    )
  )
);

drop policy if exists "realtime_voice_channel_insert_member" on realtime.messages;

create policy "realtime_voice_channel_insert_member"
on realtime.messages
for insert
to authenticated
with check (
  realtime.messages.extension in ('broadcast', 'presence')
  and public.voice_topic_kind((select realtime.topic())) in ('presence', 'base', 'camera', 'screen')
  and public.has_channel_permission(
    public.voice_channel_id_from_topic((select realtime.topic())),
    'view_channel'
  )
  and public.has_channel_permission(
    public.voice_channel_id_from_topic((select realtime.topic())),
    'join_voice'
  )
);
