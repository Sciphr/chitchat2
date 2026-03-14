-- Server soundboard: audio clips playable in voice channels.

-- 1. Create server_soundboard table.
create table if not exists public.server_soundboard (
  id uuid primary key default gen_random_uuid(),
  server_id uuid not null references public.servers(id) on delete cascade,
  name text not null,
  file_path text not null,
  created_by uuid not null,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists server_soundboard_server_idx
  on public.server_soundboard (server_id, created_at asc);

alter table public.server_soundboard enable row level security;

-- 2. RLS policies.

-- Server members can view clips.
create policy "Soundboard visible to server members"
  on public.server_soundboard
  for select
  using (
    exists (
      select 1 from public.server_members
      where server_id = server_soundboard.server_id
        and user_id = auth.uid()
    )
  );

-- Only manage_soundboard (or server owner) can add clips.
create policy "Soundboard insert requires manage_soundboard"
  on public.server_soundboard
  for insert
  with check (
    public.has_server_permission(server_id, 'manage_soundboard')
    and created_by = auth.uid()
  );

-- Only manage_soundboard (or server owner) can delete clips.
create policy "Soundboard delete requires manage_soundboard"
  on public.server_soundboard
  for delete
  using (
    public.has_server_permission(server_id, 'manage_soundboard')
  );
