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
);
