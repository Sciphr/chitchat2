create or replace function public.is_direct_conversation_member(
  conversation_id_input uuid,
  user_id_input uuid default auth.uid()
)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.direct_conversation_members
    where direct_conversation_members.conversation_id = conversation_id_input
      and direct_conversation_members.user_id = user_id_input
  );
$$;

drop policy if exists "direct_conversations_select_member" on public.direct_conversations;
create policy "direct_conversations_select_member"
on public.direct_conversations
for select
to authenticated
using (
  public.is_direct_conversation_member(direct_conversations.id)
);

drop policy if exists "direct_conversation_members_select_member" on public.direct_conversation_members;
create policy "direct_conversation_members_select_member"
on public.direct_conversation_members
for select
to authenticated
using (
  public.is_direct_conversation_member(direct_conversation_members.conversation_id)
);

drop policy if exists "direct_messages_select_member" on public.direct_messages;
create policy "direct_messages_select_member"
on public.direct_messages
for select
to authenticated
using (
  public.is_direct_conversation_member(direct_messages.conversation_id)
);

drop policy if exists "direct_messages_insert_member" on public.direct_messages;
create policy "direct_messages_insert_member"
on public.direct_messages
for insert
to authenticated
with check (
  sender_id = auth.uid()
  and public.is_direct_conversation_member(direct_messages.conversation_id)
);
