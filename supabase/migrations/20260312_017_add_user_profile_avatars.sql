alter table if exists public.user_profiles
  add column if not exists avatar_path text;

alter table if exists public.channel_messages
  add column if not exists sender_avatar_path text;

alter table if exists public.direct_messages
  add column if not exists sender_avatar_path text;

update public.channel_messages
set sender_avatar_path = user_profiles.avatar_path
from public.user_profiles
where user_profiles.id = channel_messages.sender_id
  and channel_messages.sender_avatar_path is null;

update public.direct_messages
set sender_avatar_path = user_profiles.avatar_path
from public.user_profiles
where user_profiles.id = direct_messages.sender_id
  and direct_messages.sender_avatar_path is null;

insert into storage.buckets (id, name, public)
values ('profile-assets', 'profile-assets', true)
on conflict (id) do update
set public = excluded.public;

create or replace function public.can_upload_profile_avatar(
  object_name text
)
returns boolean
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  path_parts text[] := storage.folder(object_name);
begin
  if auth.uid() is null then
    return false;
  end if;

  if coalesce(array_length(path_parts, 1), 0) < 1 then
    return false;
  end if;

  return path_parts[1] = auth.uid()::text;
end;
$$;

drop policy if exists "profile_assets_insert_self" on storage.objects;
create policy "profile_assets_insert_self"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'profile-assets'
  and public.can_upload_profile_avatar(name)
);

drop policy if exists "profile_assets_update_self" on storage.objects;
create policy "profile_assets_update_self"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'profile-assets'
  and owner_id = auth.uid()::text
)
with check (
  bucket_id = 'profile-assets'
  and public.can_upload_profile_avatar(name)
);

drop policy if exists "profile_assets_delete_self" on storage.objects;
create policy "profile_assets_delete_self"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'profile-assets'
  and owner_id = auth.uid()::text
);

drop function if exists public.list_direct_conversations();

create function public.list_direct_conversations()
returns table (
  conversation_id uuid,
  other_user_id uuid,
  other_display_name text,
  other_avatar_path text,
  last_message_at timestamptz,
  last_message_preview text,
  last_message_sender_id uuid,
  unread_count integer
)
language sql
security definer
set search_path = public
as $$
  select
    conversations.id as conversation_id,
    other_members.user_id as other_user_id,
    coalesce(user_profiles.display_name, 'Unknown') as other_display_name,
    user_profiles.avatar_path as other_avatar_path,
    conversations.last_message_at,
    conversations.last_message_preview,
    conversations.last_message_sender_id,
    coalesce((
      select count(*)::integer
      from public.direct_messages
      where direct_messages.conversation_id = conversations.id
        and direct_messages.sender_id <> auth.uid()
        and direct_messages.created_at > coalesce(self_members.last_read_at, to_timestamp(0))
    ), 0) as unread_count
  from public.direct_conversation_members as self_members
  join public.direct_conversations as conversations
    on conversations.id = self_members.conversation_id
  join public.direct_conversation_members as other_members
    on other_members.conversation_id = conversations.id
   and other_members.user_id <> self_members.user_id
  left join public.user_profiles
    on user_profiles.id = other_members.user_id
  where self_members.user_id = auth.uid()
  order by coalesce(conversations.last_message_at, conversations.created_at) desc;
$$;
