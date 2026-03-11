create extension if not exists pgcrypto;

alter table if exists public.channel_messages
  add column if not exists reply_to_message_id uuid references public.channel_messages(id) on delete set null,
  add column if not exists reply_to_body text,
  add column if not exists reply_to_sender_display_name text,
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by uuid,
  add column if not exists reactions jsonb not null default '{}'::jsonb;

create table if not exists public.direct_conversations (
  id uuid primary key default gen_random_uuid(),
  pair_key text not null unique,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  last_message_at timestamptz,
  last_message_preview text,
  last_message_sender_id uuid
);

create table if not exists public.direct_conversation_members (
  conversation_id uuid not null references public.direct_conversations(id) on delete cascade,
  user_id uuid not null,
  created_at timestamptz not null default timezone('utc', now()),
  last_read_at timestamptz not null default timezone('utc', now()),
  primary key (conversation_id, user_id)
);

create table if not exists public.direct_messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.direct_conversations(id) on delete cascade,
  sender_id uuid not null,
  sender_display_name text not null,
  body text not null,
  reply_to_message_id uuid references public.direct_messages(id) on delete set null,
  reply_to_body text,
  reply_to_sender_display_name text,
  deleted_at timestamptz,
  deleted_by uuid,
  reactions jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists direct_conversation_members_user_id_idx
on public.direct_conversation_members (user_id);

create index if not exists direct_messages_conversation_created_at_idx
on public.direct_messages (conversation_id, created_at);

alter table public.direct_conversations enable row level security;
alter table public.direct_conversation_members enable row level security;
alter table public.direct_messages enable row level security;

create or replace function public._toggle_message_reaction(
  current_reactions jsonb,
  emoji_input text,
  user_id_input uuid
)
returns jsonb
language plpgsql
as $$
declare
  result jsonb := coalesce(current_reactions, '{}'::jsonb);
  existing_user_ids text[];
  next_user_ids text[];
  normalized_emoji text := btrim(emoji_input);
  user_id_text text := user_id_input::text;
begin
  if normalized_emoji is null or normalized_emoji = '' then
    raise exception 'Emoji is required.';
  end if;

  existing_user_ids := coalesce(
    array(
      select jsonb_array_elements_text(result -> normalized_emoji)
    ),
    array[]::text[]
  );

  if user_id_text = any(existing_user_ids) then
    next_user_ids := array(
      select item
      from unnest(existing_user_ids) as item
      where item <> user_id_text
    );
  else
    next_user_ids := array_append(existing_user_ids, user_id_text);
  end if;

  if coalesce(array_length(next_user_ids, 1), 0) = 0 then
    result := result - normalized_emoji;
  else
    result := jsonb_set(
      result,
      array[normalized_emoji],
      to_jsonb(next_user_ids),
      true
    );
  end if;

  return result;
end;
$$;

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

drop trigger if exists direct_messages_sync_summary on public.direct_messages;

create trigger direct_messages_sync_summary
after insert or update of body, deleted_at, deleted_by
on public.direct_messages
for each row
execute function public.sync_direct_conversation_summary();

create or replace function public.create_or_get_direct_conversation(
  other_user_id_input uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  normalized_pair_key text;
  conversation_id_value uuid;
begin
  if current_user_id is null then
    raise exception 'You must be signed in to start a direct message.';
  end if;

  if other_user_id_input is null or other_user_id_input = current_user_id then
    raise exception 'A valid other user is required.';
  end if;

  normalized_pair_key := case
    when current_user_id::text < other_user_id_input::text
      then current_user_id::text || ':' || other_user_id_input::text
    else other_user_id_input::text || ':' || current_user_id::text
  end;

  select id
  into conversation_id_value
  from public.direct_conversations
  where pair_key = normalized_pair_key;

  if conversation_id_value is null then
    insert into public.direct_conversations (pair_key)
    values (normalized_pair_key)
    returning id into conversation_id_value;
  end if;

  insert into public.direct_conversation_members (
    conversation_id,
    user_id
  )
  values
    (conversation_id_value, current_user_id),
    (conversation_id_value, other_user_id_input)
  on conflict (conversation_id, user_id) do nothing;

  return conversation_id_value;
end;
$$;

create or replace function public.list_direct_conversations()
returns table (
  conversation_id uuid,
  other_user_id uuid,
  other_display_name text,
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

create or replace function public.toggle_channel_message_reaction(
  message_id_input uuid,
  emoji_input text
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
    raise exception 'You must be signed in to react to a message.';
  end if;

  update public.channel_messages
  set reactions = public._toggle_message_reaction(reactions, emoji_input, current_user_id)
  where id = message_id_input
    and public.has_channel_permission(channel_id, 'view_channel');

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

create or replace function public.toggle_direct_message_reaction(
  message_id_input uuid,
  emoji_input text
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
    raise exception 'You must be signed in to react to a message.';
  end if;

  update public.direct_messages
  set reactions = public._toggle_message_reaction(reactions, emoji_input, current_user_id)
  where id = message_id_input
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

drop policy if exists "direct_conversations_select_member" on public.direct_conversations;
create policy "direct_conversations_select_member"
on public.direct_conversations
for select
to authenticated
using (
  exists (
    select 1
    from public.direct_conversation_members
    where direct_conversation_members.conversation_id = direct_conversations.id
      and direct_conversation_members.user_id = auth.uid()
  )
);

drop policy if exists "direct_conversation_members_select_member" on public.direct_conversation_members;
create policy "direct_conversation_members_select_member"
on public.direct_conversation_members
for select
to authenticated
using (
  exists (
    select 1
    from public.direct_conversation_members as memberships
    where memberships.conversation_id = direct_conversation_members.conversation_id
      and memberships.user_id = auth.uid()
  )
);

drop policy if exists "direct_conversation_members_update_self" on public.direct_conversation_members;
create policy "direct_conversation_members_update_self"
on public.direct_conversation_members
for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "direct_messages_select_member" on public.direct_messages;
create policy "direct_messages_select_member"
on public.direct_messages
for select
to authenticated
using (
  exists (
    select 1
    from public.direct_conversation_members
    where direct_conversation_members.conversation_id = direct_messages.conversation_id
      and direct_conversation_members.user_id = auth.uid()
  )
);

drop policy if exists "direct_messages_insert_member" on public.direct_messages;
create policy "direct_messages_insert_member"
on public.direct_messages
for insert
to authenticated
with check (
  sender_id = auth.uid()
  and exists (
    select 1
    from public.direct_conversation_members
    where direct_conversation_members.conversation_id = direct_messages.conversation_id
      and direct_conversation_members.user_id = auth.uid()
  )
);
