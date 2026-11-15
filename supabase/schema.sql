-- Bangkok MPC — database schema (Supabase project ref: yrzwbcqargyatagcgiuy)
-- Reference copy of the migrations already applied: init_membership_schema,
-- lock_is_active_to_coaches, signup_birth_date, member_self_check_in, coupons_redeem, avatars_select_policy. Do not re-run on the live project.

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

-- ============================================================
-- member_self_check_in: สมาชิกเช็คชื่อเองด้วยรหัส 6 หลัก
-- ============================================================
alter table public.activities
  add column start_time time,
  add column end_time time,
  add constraint activities_time_order check (start_time is null or end_time is null or end_time > start_time);

-- รหัสแยกตาราง เพราะ activities อ่านได้ทุกคนที่ล็อกอิน
create table public.activity_codes (
  activity_id uuid primary key references public.activities(id) on delete cascade,
  code text not null unique check (code ~ '^[0-9]{6}$'),
  created_at timestamptz not null default now()
);
alter table public.activity_codes enable row level security;
create policy activity_codes_coach on public.activity_codes
  for all to authenticated
  using ((select public.is_coach())) with check ((select public.is_coach()));

-- นับครั้งที่กรอกรหัสผิด (เข้าถึงผ่านฟังก์ชันเท่านั้น จึงไม่มี policy)
create table public.checkin_failures (
  id bigint generated always as identity primary key,
  member_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index checkin_failures_member_idx on public.checkin_failures (member_id, created_at desc);
alter table public.checkin_failures enable row level security;

create or replace function public.gen_activity_code() returns text
language plpgsql set search_path = public as $$
declare c text;
begin
  loop
    c := (100000 + floor(random() * 900000))::int::text;
    exit when not exists (select 1 from public.activity_codes where code = c);
  end loop;
  return c;
end $$;
revoke execute on function public.gen_activity_code() from public, anon, authenticated;

create or replace function public.activities_make_code() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.activity_codes (activity_id, code) values (new.id, public.gen_activity_code());
  return new;
end $$;
revoke execute on function public.activities_make_code() from public, anon, authenticated;
create trigger activities_make_code after insert on public.activities
  for each row execute function public.activities_make_code();

insert into public.activity_codes (activity_id, code)
select id, public.gen_activity_code() from public.activities
on conflict do nothing;

create or replace function public.regenerate_activity_code(p_activity_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if not public.is_coach() then raise exception 'not allowed'; end if;
  c := public.gen_activity_code();
  update public.activity_codes set code = c, created_at = now() where activity_id = p_activity_id;
  if not found then insert into public.activity_codes (activity_id, code) values (p_activity_id, c); end if;
  return c;
end $$;
revoke execute on function public.regenerate_activity_code(uuid) from public, anon;
grant execute on function public.regenerate_activity_code(uuid) to authenticated;

-- ตรวจรหัส + ช่วงเวลา (Asia/Bangkok) ฝั่งเซิร์ฟเวอร์
-- เปิดก่อนเริ่ม 30 นาที ปิดเมื่อถึงเวลาจบ (ไม่ระบุเวลา = เปิดทั้งวันของวันกิจกรรม)
-- ผิดเกิน 5 ครั้งใน 10 นาที = ล็อกชั่วคราว
create or replace function public.self_check_in(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  code_in text := regexp_replace(coalesce(p_code, ''), '[^0-9]', '', 'g');
  prof public.profiles%rowtype;
  act public.activities%rowtype;
  opens timestamptz; closes timestamptz;
  fails int;
begin
  if uid is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  select * into prof from public.profiles where id = uid;
  if not found or prof.role <> 'student' or not prof.is_active then
    return jsonb_build_object('ok', false, 'reason', 'not_member');
  end if;

  delete from public.checkin_failures where member_id = uid and created_at < now() - interval '1 day';
  select count(*) into fails from public.checkin_failures
    where member_id = uid and created_at > now() - interval '10 minutes';
  if fails >= 5 then return jsonb_build_object('ok', false, 'reason', 'locked'); end if;

  select a.* into act from public.activity_codes c join public.activities a on a.id = c.activity_id
    where c.code = code_in;
  if not found then
    insert into public.checkin_failures (member_id) values (uid);
    return jsonb_build_object('ok', false, 'reason', 'wrong_code', 'left', greatest(0, 4 - fails));
  end if;

  opens  := ((act.activity_date + coalesce(act.start_time, time '00:00')) at time zone 'Asia/Bangkok') - interval '30 minutes';
  closes := (act.activity_date + coalesce(act.end_time, time '23:59:59')) at time zone 'Asia/Bangkok';
  if now() < opens then
    return jsonb_build_object('ok', false, 'reason', 'too_early', 'title', act.title, 'opens_at', opens);
  end if;
  if now() > closes then
    return jsonb_build_object('ok', false, 'reason', 'closed', 'title', act.title);
  end if;

  insert into public.attendance (activity_id, member_id, checked_in_by)
    values (act.id, uid, uid) on conflict (activity_id, member_id) do nothing;
  if found then
    return jsonb_build_object('ok', true, 'reason', 'checked_in', 'title', act.title);
  end if;
  return jsonb_build_object('ok', true, 'reason', 'already', 'title', act.title);
end $$;
revoke execute on function public.self_check_in(text) from public, anon;
grant execute on function public.self_check_in(text) to authenticated;

-- ============================================================
-- coupons_redeem: คูปองสมนาคุณ โค้ชสร้าง สมาชิกกรอกโค้ดแลก
-- ============================================================
create table public.coupons (
  id uuid primary key default gen_random_uuid(),
  code text unique check (code ~ '^[A-Z0-9]{4,20}$'),   -- trigger เติมให้ถ้าไม่ระบุ
  title text not null check (length(btrim(title)) > 0),
  description text,
  expires_at date,                      -- ใช้ได้ถึงสิ้นวันนี้ (เวลาไทย) ว่าง = ไม่หมดอายุ
  max_uses int check (max_uses is null or max_uses > 0),  -- ว่าง = ไม่จำกัดจำนวน
  is_active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint coupons_code_present check (code is not null)
);
alter table public.coupons enable row level security;

create table public.coupon_redemptions (
  id uuid primary key default gen_random_uuid(),
  coupon_id uuid not null references public.coupons(id) on delete cascade,
  member_id uuid not null references public.profiles(id) on delete cascade,
  redeemed_at timestamptz not null default now(),
  unique (coupon_id, member_id)
);
create index coupon_redemptions_member_idx on public.coupon_redemptions (member_id, redeemed_at desc);
alter table public.coupon_redemptions enable row level security;

create table public.coupon_failures (
  id bigint generated always as identity primary key,
  member_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index coupon_failures_member_idx on public.coupon_failures (member_id, created_at desc);
alter table public.coupon_failures enable row level security;   -- ไม่มี policy: ใช้ผ่านฟังก์ชันเท่านั้น

create policy coupons_coach on public.coupons for all to authenticated
  using ((select public.is_coach())) with check ((select public.is_coach()));
create policy coupons_redeemer_select on public.coupons for select to authenticated
  using (exists (select 1 from public.coupon_redemptions r where r.coupon_id = coupons.id and r.member_id = (select auth.uid())));
create policy redemptions_select on public.coupon_redemptions for select to authenticated
  using (member_id = (select auth.uid()) or (select public.is_coach()));
create policy redemptions_coach_delete on public.coupon_redemptions for delete to authenticated
  using ((select public.is_coach()));

create or replace function public.gen_coupon_code() returns text
language plpgsql set search_path = public as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  c text;
begin
  loop
    c := '';
    for i in 1..8 loop
      c := c || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.coupons where code = c);
  end loop;
  return c;
end $$;
revoke execute on function public.gen_coupon_code() from public, anon, authenticated;

create or replace function public.coupons_fill_code() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.code is null or btrim(new.code) = '' then new.code := public.gen_coupon_code(); end if;
  new.code := upper(btrim(new.code));
  return new;
end $$;
revoke execute on function public.coupons_fill_code() from public, anon, authenticated;
create trigger coupons_fill_code before insert on public.coupons
  for each row execute function public.coupons_fill_code();

-- แลกคูปอง: ตรวจโค้ด/วันหมดอายุ/โควตา/แลกซ้ำ ฝั่งเซิร์ฟเวอร์ ล็อกแถวกันแย่งใบสุดท้าย
-- กรอกผิดเกิน 5 ครั้งใน 10 นาที = ล็อกชั่วคราว
create or replace function public.redeem_coupon(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  code_in text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  prof public.profiles%rowtype;
  cp public.coupons%rowtype;
  fails int; used int;
begin
  if uid is null then return jsonb_build_object('ok', false, 'reason', 'auth'); end if;
  select * into prof from public.profiles where id = uid;
  if not found or prof.role <> 'student' or not prof.is_active then
    return jsonb_build_object('ok', false, 'reason', 'not_member');
  end if;

  delete from public.coupon_failures where member_id = uid and created_at < now() - interval '1 day';
  select count(*) into fails from public.coupon_failures
    where member_id = uid and created_at > now() - interval '10 minutes';
  if fails >= 5 then return jsonb_build_object('ok', false, 'reason', 'locked'); end if;

  select * into cp from public.coupons where code = code_in for update;
  if not found then
    insert into public.coupon_failures (member_id) values (uid);
    return jsonb_build_object('ok', false, 'reason', 'wrong_code', 'left', greatest(0, 4 - fails));
  end if;

  if exists (select 1 from public.coupon_redemptions where coupon_id = cp.id and member_id = uid) then
    return jsonb_build_object('ok', true, 'reason', 'already', 'title', cp.title);
  end if;
  if not cp.is_active then return jsonb_build_object('ok', false, 'reason', 'inactive', 'title', cp.title); end if;
  if cp.expires_at is not null and (now() at time zone 'Asia/Bangkok')::date > cp.expires_at then
    return jsonb_build_object('ok', false, 'reason', 'expired', 'title', cp.title);
  end if;
  if cp.max_uses is not null then
    select count(*) into used from public.coupon_redemptions where coupon_id = cp.id;
    if used >= cp.max_uses then return jsonb_build_object('ok', false, 'reason', 'sold_out', 'title', cp.title); end if;
  end if;

  insert into public.coupon_redemptions (coupon_id, member_id) values (cp.id, uid);
  return jsonb_build_object('ok', true, 'reason', 'redeemed', 'title', cp.title, 'description', cp.description);
end $$;
revoke execute on function public.redeem_coupon(text) from public, anon;
grant execute on function public.redeem_coupon(text) to authenticated;

-- ============================================================
-- avatars_select_policy: อัปโหลดแบบ upsert ต้องมี SELECT policy
-- (ก่อนหน้านี้ทุกการอัปโหลดรูปโปรไฟล์ถูกปฏิเสธด้วย HTTP 400 / RLS)
-- ============================================================
create policy avatars_select on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
