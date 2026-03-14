-- Add status and activity_text to user_profiles.
-- status: 'online' | 'away' | 'dnd' | 'invisible'  (persisted across sessions)
-- activity_text: optional custom activity string

alter table if exists public.user_profiles
  add column if not exists status text not null default 'online'
    check (status in ('online', 'away', 'dnd', 'invisible')),
  add column if not exists activity_text text;

-- Allow authenticated users to update their own status / activity.
-- The existing RLS "Users can update own profile" policy already covers
-- update on user_profiles where id = auth.uid(), so no new policy is needed.

-- Function to set current user's status.
create or replace function public.set_user_status(
  status_input text,
  activity_text_input text default null
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
    raise exception 'You must be signed in to update your status.';
  end if;

  if status_input not in ('online', 'away', 'dnd', 'invisible') then
    raise exception 'Invalid status value.';
  end if;

  update public.user_profiles
  set
    status = status_input,
    activity_text = activity_text_input
  where id = current_user_id;
end;
$$;

grant execute on function public.set_user_status(text, text)
to authenticated;
