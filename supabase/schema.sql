-- Bangkok MPC — database schema (Supabase project ref: yrzwbcqargyatagcgiuy)
-- Reference copy of the migrations already applied: init_membership_schema,
-- lock_is_active_to_coaches, signup_birth_date. Do not re-run on the live project.

create type public.app_role as enum ('student', 'coach');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  role public.app_role not null default 'student',
  full_name text not null default '',
  nickname text not null default '',
  phone text,
  birth_date date,
  avatar_url text,
  line_user_id text unique,
  is_active boolean not null default true,
  joined_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.activities (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  activity_date date not null,
  location text,
  discipline text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index activities_date_idx on public.activities(activity_date);
create index activities_created_by_idx on public.activities(created_by);

create table public.attendance (
  id uuid primary key default gen_random_uuid(),
  activity_id uuid not null references public.activities(id) on delete cascade,
  member_id uuid not null references public.profiles(id) on delete cascade,
  checked_in_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (activity_id, member_id)
);
create index attendance_member_idx on public.attendance(member_id);
create index attendance_checked_in_by_idx on public.attendance(checked_in_by);

create table public.competitions (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  competition_date date not null,
  location text,
  level text,
  created_at timestamptz not null default now()
);
create index competitions_date_idx on public.competitions(competition_date);

create table public.results (
  id uuid primary key default gen_random_uuid(),
  competition_id uuid not null references public.competitions(id) on delete cascade,
  member_id uuid not null references public.profiles(id) on delete cascade,
  discipline text not null default 'overall'
    check (discipline in ('overall','fencing','swimming','riding','laser_run')),
  score numeric,
  placement int,
  points numeric not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  unique (competition_id, member_id, discipline)
);
create index results_member_idx on public.results(member_id);

-- helpers
create function public.is_coach()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = (select auth.uid()) and p.role = 'coach' and p.is_active
  );
$$;
revoke execute on function public.is_coach() from public, anon;
grant execute on function public.is_coach() to authenticated;

create function public.touch_updated_at()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

-- profile is created on signup; role is always student
create function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  bd date;
begin
  begin
    bd := nullif(new.raw_user_meta_data->>'birth_date', '')::date;
  exception when others then
    bd := null;
  end;
  insert into public.profiles (id, full_name, nickname, phone, birth_date)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', ''),
    coalesce(new.raw_user_meta_data->>'nickname', ''),
    nullif(new.raw_user_meta_data->>'phone', ''),
    bd
  );
  return new;
end;
$$;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- coach-only changes
create function public.set_member_role(p_member uuid, p_role public.app_role)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_coach() then
    raise exception 'only coaches can change roles';
  end if;
  update public.profiles set role = p_role where id = p_member;
end;
$$;
revoke execute on function public.set_member_role(uuid, public.app_role) from public, anon;
grant execute on function public.set_member_role(uuid, public.app_role) to authenticated;

create function public.set_member_active(p_member uuid, p_active boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_coach() then
    raise exception 'only coaches can change member status';
  end if;
  update public.profiles set is_active = p_active where id = p_member;
end;
$$;
revoke execute on function public.set_member_active(uuid, boolean) from public, anon;
grant execute on function public.set_member_active(uuid, boolean) to authenticated;

-- club ranking (visible to every member, exposes only display name + totals)
create function public.club_ranking(p_year int default null)
returns table (
  member_id uuid, display_name text, avatar_url text,
  total_points numeric, competitions int, best_placement int, rank bigint
)
language sql stable security definer set search_path = ''
as $$
  with agg as (
    select r.member_id,
           sum(r.points) as total_points,
           count(distinct r.competition_id)::int as competitions,
           min(r.placement) as best_placement
    from public.results r
    join public.competitions c on c.id = r.competition_id
    where r.discipline = 'overall'
      and (p_year is null or extract(year from c.competition_date) = p_year)
    group by r.member_id
  )
  select a.member_id,
         coalesce(nullif(p.nickname, ''), p.full_name) as display_name,
         p.avatar_url, a.total_points, a.competitions, a.best_placement,
         rank() over (order by a.total_points desc)
  from agg a
  join public.profiles p on p.id = a.member_id and p.is_active
  where (select auth.uid()) is not null
  order by 7, 2;
$$;
revoke execute on function public.club_ranking(int) from public, anon;
grant execute on function public.club_ranking(int) to authenticated;

-- RLS
alter table public.profiles enable row level security;
alter table public.activities enable row level security;
alter table public.attendance enable row level security;
alter table public.competitions enable row level security;
alter table public.results enable row level security;

create policy profiles_select on public.profiles for select to authenticated
  using (id = (select auth.uid()) or (select public.is_coach()));
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));
create policy profiles_update_coach on public.profiles for update to authenticated
  using ((select public.is_coach())) with check ((select public.is_coach()));

-- users can only edit personal fields; role/is_active changes go through coach functions
revoke update on public.profiles from authenticated;
grant update (full_name, nickname, phone, birth_date, avatar_url) on public.profiles to authenticated;

create policy activities_select on public.activities for select to authenticated using (true);
create policy activities_write on public.activities for all to authenticated
  using ((select public.is_coach())) with check ((select public.is_coach()));

create policy attendance_select on public.attendance for select to authenticated
  using (member_id = (select auth.uid()) or (select public.is_coach()));
create policy attendance_write on public.attendance for all to authenticated
  using ((select public.is_coach())) with check ((select public.is_coach()));

create policy competitions_select on public.competitions for select to authenticated using (true);
create policy competitions_write on public.competitions for all to authenticated
  using ((select public.is_coach())) with check ((select public.is_coach()));

create policy results_select on public.results for select to authenticated
  using (member_id = (select auth.uid()) or (select public.is_coach()));
create policy results_write on public.results for all to authenticated
  using ((select public.is_coach())) with check ((select public.is_coach()));

-- avatars bucket
insert into storage.buckets (id, name, public) values ('avatars', 'avatars', true)
  on conflict (id) do nothing;
create policy avatars_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_update on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy avatars_delete on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
