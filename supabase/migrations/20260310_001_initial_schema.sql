create extension if not exists "pgcrypto";

create table if not exists public.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 1 and 80),
  created_by uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.room_members (
  room_id uuid not null references public.rooms (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  joined_at timestamptz not null default timezone('utc', now()),
  primary key (room_id, user_id)
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms (id) on delete cascade,
  sender_id uuid not null references auth.users (id) on delete cascade,
  sender_display_name text not null check (char_length(trim(sender_display_name)) between 1 and 80),
  body text not null check (char_length(trim(body)) between 1 and 4000),
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists room_members_user_id_idx
  on public.room_members (user_id, room_id);

create index if not exists messages_room_created_at_idx
  on public.messages (room_id, created_at);

do $$
begin
  alter publication supabase_realtime add table public.messages;
exception
  when duplicate_object then null;
end
$$;

create or replace function public.handle_room_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.room_members (room_id, user_id)
  values (new.id, new.created_by)
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists on_room_created_add_creator on public.rooms;

create trigger on_room_created_add_creator
after insert on public.rooms
for each row execute function public.handle_room_created();

create or replace function public.is_room_member(target_room uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.room_members rm
    where rm.room_id = target_room
      and rm.user_id = auth.uid()
  );
$$;

create or replace function public.room_id_from_topic(topic_name text)
returns uuid
language sql
stable
as $$
  select nullif(split_part(topic_name, ':', 2), '')::uuid;
$$;

alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.messages enable row level security;

drop policy if exists "rooms_select_member" on public.rooms;
create policy "rooms_select_member"
on public.rooms
for select
to authenticated
using (public.is_room_member(id));

drop policy if exists "rooms_insert_authenticated" on public.rooms;
create policy "rooms_insert_authenticated"
on public.rooms
for insert
to authenticated
with check (auth.uid() = created_by);

drop policy if exists "rooms_update_creator" on public.rooms;
create policy "rooms_update_creator"
on public.rooms
for update
to authenticated
using (created_by = auth.uid())
with check (created_by = auth.uid());

drop policy if exists "room_members_select_member" on public.room_members;
create policy "room_members_select_member"
on public.room_members
for select
to authenticated
using (public.is_room_member(room_id));

drop policy if exists "room_members_insert_self" on public.room_members;
create policy "room_members_insert_self"
on public.room_members
for insert
to authenticated
with check (auth.uid() = user_id);

drop policy if exists "room_members_delete_self" on public.room_members;
create policy "room_members_delete_self"
on public.room_members
for delete
to authenticated
using (auth.uid() = user_id or public.is_room_member(room_id));

drop policy if exists "messages_select_member" on public.messages;
create policy "messages_select_member"
on public.messages
for select
to authenticated
using (public.is_room_member(room_id));

drop policy if exists "messages_insert_member" on public.messages;
create policy "messages_insert_member"
on public.messages
for insert
to authenticated
with check (
  auth.uid() = sender_id
  and public.is_room_member(room_id)
);

alter table realtime.messages enable row level security;

drop policy if exists "realtime_room_member_select" on realtime.messages;
create policy "realtime_room_member_select"
on realtime.messages
for select
to authenticated
using (
  realtime.messages.extension in ('broadcast', 'presence')
  and public.is_room_member(public.room_id_from_topic(realtime.topic()))
);

drop policy if exists "realtime_room_member_insert" on realtime.messages;
create policy "realtime_room_member_insert"
on realtime.messages
for insert
to authenticated
with check (
  realtime.messages.extension in ('broadcast', 'presence')
  and public.is_room_member(public.room_id_from_topic(realtime.topic()))
);
