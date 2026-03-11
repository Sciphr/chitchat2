drop policy if exists "realtime_server_presence_select_member" on realtime.messages;

create policy "realtime_server_presence_select_member"
on realtime.messages
for select
to authenticated
using (
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
