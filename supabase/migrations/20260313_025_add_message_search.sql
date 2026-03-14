-- Full-text search for channel messages.

-- Add tsvector generated column to channel_messages.
alter table if exists public.channel_messages
  add column if not exists search_vector tsvector
    generated always as (
      to_tsvector('english', coalesce(body, ''))
    ) stored;

-- GIN index for fast full-text lookup.
create index if not exists channel_messages_search_idx
  on public.channel_messages using gin(search_vector);

-- search_server_messages RPC.
-- Returns messages matching the query in channels the caller can view,
-- within a given server. Results ordered by rank then recency.
create or replace function public.search_server_messages(
  server_id_input uuid,
  query_input text,
  page_size int default 25
)
returns table (
  id uuid,
  channel_id uuid,
  channel_name text,
  body text,
  sender_id uuid,
  sender_display_name text,
  sender_avatar_path text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  normalized_query text := trim(query_input);
  tsq tsquery;
begin
  if normalized_query = '' then
    return;
  end if;

  tsq := plainto_tsquery('english', normalized_query);

  return query
    select
      cm.id,
      cm.channel_id,
      ch.name as channel_name,
      cm.body,
      cm.sender_id,
      cm.sender_display_name,
      cm.sender_avatar_path,
      cm.created_at
    from public.channel_messages cm
    join public.channels ch on ch.id = cm.channel_id
    where ch.server_id = server_id_input
      and cm.deleted_at is null
      and cm.search_vector @@ tsq
      -- Caller must be able to view the channel.
      and (
        exists (
          select 1 from public.servers
          where id = server_id_input and owner_id = auth.uid()
        )
        or public.has_channel_permission(cm.channel_id, 'view_channel')
      )
    order by ts_rank(cm.search_vector, tsq) desc, cm.created_at desc
    limit page_size;
end;
$$;

grant execute on function public.search_server_messages(uuid, text, int)
to authenticated;
