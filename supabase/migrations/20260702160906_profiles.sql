-- Onboarding profile: answers + completion marker. Named user_profiles to avoid
-- colliding with any pre-existing `profiles` table in the project.
create table if not exists public.user_profiles (
  user_id uuid primary key references auth.users (id) on delete cascade,
  editing_domain text,
  onboarding_completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.user_profiles enable row level security;

drop policy if exists "user_profiles_select_own" on public.user_profiles;
create policy "user_profiles_select_own" on public.user_profiles
  for select using (auth.uid() = user_id);

drop policy if exists "user_profiles_insert_own" on public.user_profiles;
create policy "user_profiles_insert_own" on public.user_profiles
  for insert with check (auth.uid() = user_id);

drop policy if exists "user_profiles_update_own" on public.user_profiles;
create policy "user_profiles_update_own" on public.user_profiles
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
