create table if not exists public.user_profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 1 and 80),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create or replace function public.set_profile_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

drop trigger if exists on_user_profiles_updated on public.user_profiles;
create trigger on_user_profiles_updated
before update on public.user_profiles
for each row execute function public.set_profile_updated_at();

alter table public.user_profiles enable row level security;

drop policy if exists "user_profiles_select_authenticated" on public.user_profiles;
create policy "user_profiles_select_authenticated"
on public.user_profiles
for select
to authenticated
using (true);

drop policy if exists "user_profiles_insert_self" on public.user_profiles;
create policy "user_profiles_insert_self"
on public.user_profiles
for insert
to authenticated
with check (auth.uid() = id);

drop policy if exists "user_profiles_update_self" on public.user_profiles;
create policy "user_profiles_update_self"
on public.user_profiles
for update
to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);

drop policy if exists "channel_messages_insert_member" on public.channel_messages;
create policy "channel_messages_insert_member"
on public.channel_messages
for insert
to authenticated
with check (
  auth.uid() = sender_id
  and public.is_server_member(public.channel_server_id(channel_id))
  and public.channel_kind_of(channel_id) = 'text'
  and public.has_server_permission(
    public.channel_server_id(channel_id),
    'send_messages'
  )
);

drop policy if exists "realtime_voice_channel_select_member" on realtime.messages;
create policy "realtime_voice_channel_select_member"
on realtime.messages
for select
to authenticated
using (
  realtime.messages.extension in ('broadcast', 'presence')
  and public.is_server_member(
    public.channel_server_id(public.voice_channel_id_from_topic(realtime.topic()))
  )
  and public.channel_kind_of(public.voice_channel_id_from_topic(realtime.topic())) = 'voice'
  and public.has_server_permission(
    public.channel_server_id(public.voice_channel_id_from_topic(realtime.topic())),
    'join_voice'
  )
);

drop policy if exists "realtime_voice_channel_insert_member" on realtime.messages;
create policy "realtime_voice_channel_insert_member"
on realtime.messages
for insert
to authenticated
with check (
  realtime.messages.extension in ('broadcast', 'presence')
  and public.is_server_member(
    public.channel_server_id(public.voice_channel_id_from_topic(realtime.topic()))
  )
  and public.channel_kind_of(public.voice_channel_id_from_topic(realtime.topic())) = 'voice'
  and public.has_server_permission(
    public.channel_server_id(public.voice_channel_id_from_topic(realtime.topic())),
    'join_voice'
  )
);
