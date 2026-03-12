grant execute on function public.is_direct_conversation_member(uuid, uuid)
to authenticated;

grant execute on function public.create_or_get_direct_conversation(uuid)
to authenticated;

grant execute on function public.list_direct_conversations()
to authenticated;

grant execute on function public.delete_direct_message(uuid)
to authenticated;

grant execute on function public.toggle_direct_message_reaction(uuid, text)
to authenticated;
