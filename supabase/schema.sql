-- BMS Carrom — Supabase schema (v7, accounts + friends + invites)
-- Run this in the Supabase dashboard SQL editor (see docs/supabase-setup.md).
-- Free tier, no card needed. Uses Supabase Auth (anonymous sign-in +
-- email OTP) — the game client never uses the service_role key.

-- ---------------------------------------------------------------- profiles
-- One row per player. id = the Supabase Auth user id (anonymous sign-in
-- first, Gmail linked later by OTP verification). Coins/level/XP/stats
-- and shop ownership live here so a reinstall + login restores them.
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  gmail text unique not null,
  display_name text not null,
  coins integer not null default 1000,
  xp integer not null default 0,
  matches_played integer not null default 0,
  matches_won integer not null default 0,
  online_wins integer not null default 0,
  queens_covered integer not null default 0,
  owned_boards jsonb not null default '["classic"]'::jsonb,
  owned_strikers jsonb not null default '["classic"]'::jsonb,
  equipped_board text not null default 'classic',
  equipped_striker text not null default 'classic',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Keep updated_at honest on every write.
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- ----------------------------------------------------------------- invites
-- One row per invitee. A 4-player invite is 3 rows sharing one group_id.
-- status: pending -> accepted | declined | expired | cancelled.
-- The match room code IS the group_id (the game server starts the match
-- when every player in the group has joined it).
create table if not exists public.invites (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null,
  from_id uuid not null references public.profiles (id) on delete cascade,
  to_id uuid not null references public.profiles (id) on delete cascade,
  from_name text not null,
  to_name text not null default '',
  mode text not null check (mode in ('2p', '4p')),
  stake integer not null default 0,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'declined', 'expired', 'cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists invites_to_idx on public.invites (to_id, status, created_at desc);
create index if not exists invites_group_idx on public.invites (group_id, status);
drop trigger if exists invites_touch on public.invites;
create trigger invites_touch before update on public.invites
  for each row execute function public.touch_updated_at();

-- ------------------------------------------------------- friend search RPC
-- Search by display name only (never by Gmail — Gmail is login-only).
-- Returns only id + display name + level (xp/500+1), never coins or Gmail.
-- Security definer so the search works with RLS on; the caller is
-- excluded from their own results.
create or replace function public.search_players(q text, exclude_id uuid)
returns table (id uuid, display_name text, level integer)
language sql security definer stable as $$
  select p.id, p.display_name, (p.xp / 500 + 1)::integer as level
  from public.profiles p
  where p.id <> exclude_id
    and p.display_name ilike '%' || q || '%'
  order by p.display_name
  limit 20;
$$;

-- ---------------------------------------------------------------------- RLS
alter table public.profiles enable row level security;
alter table public.invites enable row level security;

-- Profiles: anyone signed in can read a profile (needed for the invite
-- box to show a sender's name/level); only the owner can insert/update
-- their own row.
drop policy if exists "profiles read for signed-in users" on public.profiles;
create policy "profiles read for signed-in users" on public.profiles
  for select to authenticated using (true);
drop policy if exists "profiles insert own row" on public.profiles;
create policy "profiles insert own row" on public.profiles
  for insert to authenticated with check (auth.uid() = id);
drop policy if exists "profiles update own row" on public.profiles;
create policy "profiles update own row" on public.profiles
  for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

-- Invites: sender and recipient can read a row; the sender inserts;
-- the recipient (or sender, to cancel) updates the status.
drop policy if exists "invites read for parties" on public.invites;
create policy "invites read for parties" on public.invites
  for select to authenticated using (auth.uid() = from_id or auth.uid() = to_id);
drop policy if exists "invites insert by sender" on public.invites;
create policy "invites insert by sender" on public.invites
  for insert to authenticated with check (auth.uid() = from_id);
drop policy if exists "invites update by parties" on public.invites;
create policy "invites update by parties" on public.invites
  for update to authenticated using (auth.uid() = from_id or auth.uid() = to_id);

-- ----------------------------------------------------------------- Realtime
-- Invite delivery: clients subscribe to postgres_changes on invites.
alter publication supabase_realtime add table public.invites;
