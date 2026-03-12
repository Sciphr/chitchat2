alter table if exists public.channel_messages
  add column if not exists attachments jsonb not null default '[]'::jsonb;

alter table if exists public.direct_messages
  add column if not exists attachments jsonb not null default '[]'::jsonb;

insert into storage.buckets (id, name, public)
values ('message-attachments', 'message-attachments', true)
on conflict (id) do update
set public = excluded.public;

create or replace function public.can_upload_message_attachment(
  object_name text
)
returns boolean
language plpgsql
security definer
set search_path = public, storage
as $$
declare
  path_parts text[] := storage.folder(object_name);
  scope_value text;
  scope_id_value uuid;
begin
  if auth.uid() is null then
    return false;
  end if;

  if coalesce(array_length(path_parts, 1), 0) < 4 then
    return false;
  end if;

  scope_value := path_parts[1];

  begin
    scope_id_value := path_parts[2]::uuid;
  exception
    when others then
      return false;
  end;

  if path_parts[3] <> auth.uid()::text then
    return false;
  end if;

  if scope_value = 'channel' then
    return exists (
      select 1
      from public.channels
      join public.server_members
        on server_members.server_id = channels.server_id
      where channels.id = scope_id_value
        and server_members.user_id = auth.uid()
    );
  end if;

  if scope_value = 'direct' then
    return public.is_direct_conversation_member(scope_id_value);
  end if;

  return false;
end;
$$;

drop policy if exists "message_attachments_insert_member" on storage.objects;
create policy "message_attachments_insert_member"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'message-attachments'
  and public.can_upload_message_attachment(name)
);

drop policy if exists "message_attachments_delete_owner" on storage.objects;
create policy "message_attachments_delete_owner"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'message-attachments'
  and owner_id = auth.uid()::text
);

create or replace function public.sync_direct_conversation_summary()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  conversation_id_value uuid := coalesce(new.conversation_id, old.conversation_id);
  latest_message record;
begin
  select
    direct_messages.created_at,
    direct_messages.sender_id,
    case
      when direct_messages.deleted_at is not null then 'Message deleted.'
      when nullif(btrim(direct_messages.body), '') is null
        and jsonb_array_length(coalesce(direct_messages.attachments, '[]'::jsonb)) > 0
        then case
          when jsonb_array_length(coalesce(direct_messages.attachments, '[]'::jsonb)) = 1
            then 'Sent an attachment.'
          else
            'Sent attachments.'
        end
      else left(direct_messages.body, 160)
    end as preview
  into latest_message
  from public.direct_messages
  where direct_messages.conversation_id = conversation_id_value
  order by direct_messages.created_at desc
  limit 1;

  update public.direct_conversations
  set
    updated_at = timezone('utc', now()),
    last_message_at = latest_message.created_at,
    last_message_preview = latest_message.preview,
    last_message_sender_id = latest_message.sender_id
  where id = conversation_id_value;

  if tg_op = 'INSERT' then
    update public.direct_conversation_members
    set last_read_at = greatest(last_read_at, new.created_at)
    where conversation_id = new.conversation_id
      and user_id = new.sender_id;
  end if;

  return coalesce(new, old);
end;
$$;

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
    );

  if not found then
    raise exception 'Channel message not found or not permitted.';
  end if;
end;
$$;

create or replace function public.delete_direct_message(
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

  update public.direct_messages
  set
    body = 'Message deleted.',
    attachments = '[]'::jsonb,
    deleted_at = timezone('utc', now()),
    deleted_by = current_user_id
  where id = message_id_input
    and sender_id = current_user_id
    and exists (
      select 1
      from public.direct_conversation_members
      where direct_conversation_members.conversation_id = direct_messages.conversation_id
        and direct_conversation_members.user_id = current_user_id
    );

  if not found then
    raise exception 'Direct message not found or not permitted.';
  end if;
end;
$$;
