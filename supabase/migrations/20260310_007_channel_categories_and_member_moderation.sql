create table if not exists public.channel_categories (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers (id) on delete cascade,
  name text not null check (char_length(trim(name)) between 1 and 80),
  position int not null default 0,
  created_by uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists channel_categories_server_position_idx
  on public.channel_categories (server_id, position, created_at);

alter table public.channels
  add column if not exists category_id uuid references public.channel_categories (id) on delete set null;

create index if not exists channels_server_category_position_idx
  on public.channels (server_id, category_id, position, created_at);

create or replace function public.category_server_id(target_category uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select cc.server_id
  from public.channel_categories cc
  where cc.id = target_category;
$$;

create or replace function public.channel_category_matches_server(
  target_category uuid,
  target_server uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select case
    when target_category is null then true
    else exists (
      select 1
      from public.channel_categories cc
      where cc.id = target_category
        and cc.server_id = target_server
    )
  end;
$$;

alter table public.channel_categories enable row level security;

drop policy if exists "channel_categories_select_member" on public.channel_categories;
create policy "channel_categories_select_member"
on public.channel_categories
for select
to authenticated
using (public.is_server_member(server_id));

drop policy if exists "channel_categories_manage_channels" on public.channel_categories;
create policy "channel_categories_manage_channels"
on public.channel_categories
for all
to authenticated
using (public.has_server_permission(server_id, 'manage_channels'))
with check (public.has_server_permission(server_id, 'manage_channels'));

drop policy if exists "channels_insert_manage_channels" on public.channels;
create policy "channels_insert_manage_channels"
on public.channels
for insert
to authenticated
with check (
  auth.uid() = created_by
  and public.has_server_permission(server_id, 'manage_channels')
  and public.channel_category_matches_server(category_id, server_id)
);

drop policy if exists "channels_update_manage_channels" on public.channels;
create policy "channels_update_manage_channels"
on public.channels
for update
to authenticated
using (public.has_server_permission(server_id, 'manage_channels'))
with check (
  public.has_server_permission(server_id, 'manage_channels')
  and public.channel_category_matches_server(category_id, server_id)
);

drop policy if exists "server_members_delete_self_or_owner" on public.server_members;
drop policy if exists "server_members_delete_self_or_manage_server" on public.server_members;
create policy "server_members_delete_self_or_manage_server"
on public.server_members
for delete
to authenticated
using (
  auth.uid() = user_id
  or public.has_server_permission(server_id, 'manage_server')
);
