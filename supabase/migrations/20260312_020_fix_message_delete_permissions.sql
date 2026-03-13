create or replace function public.delete_channel_message(
  message_id_input uuid
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
    raise exception 'You must be signed in to delete a message.';
  end if;

  update public.channel_messages
  set
    body = 'Message deleted.',
    attachments = '[]'::jsonb,
    deleted_at = timezone('utc', now()),
    deleted_by = current_user_id
  where id = message_id_input
    and (
      sender_id = current_user_id
      or public.has_channel_permission(channel_id, 'manage_messages')
      or exists (
        select 1
        from public.channels
        join public.servers on servers.id = channels.server_id
        where channels.id = channel_messages.channel_id
          and servers.owner_id = current_user_id
      )
    );

  if not found then
    raise exception 'Channel message not found or not permitted.';
  end if;
end;
$$;

grant execute on function public.delete_channel_message(uuid)
to authenticated;

grant execute on function public.toggle_channel_message_reaction(uuid, text)
to authenticated;

grant execute on function public.delete_direct_message(uuid)
to authenticated;

grant execute on function public.toggle_direct_message_reaction(uuid, text)
to authenticated;
