-- Love Ticket: admin, stamps, relationship score, daily mission and special coupon upgrade.
-- Run this WHOLE file once in Supabase SQL Editor after the diary SQL.

-- Mark the designated account as admin (run once; safe to run again).
update auth.users
set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
where id = 'd1ae4d14-9ecc-435d-a239-ad65d8314f1e';

alter table public.coupons add column if not exists coupon_type text not null default 'normal'
  check (coupon_type in ('normal','special'));
alter table public.coupons add column if not exists is_revealed boolean not null default false;

create table if not exists public.love_stamp_cards (
  couple_id uuid primary key references public.couples(id) on delete cascade,
  stamps integer not null default 0 check (stamps between 0 and 10),
  updated_at timestamptz not null default now()
);

create table if not exists public.love_daily_missions (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references public.couples(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  mission_key text not null,
  completed_on date not null default current_date,
  created_at timestamptz not null default now(),
  unique (couple_id, user_id, mission_key, completed_on)
);

alter table public.couple_relationship alter column score type numeric(5,1) using score::numeric;
alter table public.love_stamp_cards enable row level security;
alter table public.love_daily_missions enable row level security;

drop policy if exists "Members can view stamps" on public.love_stamp_cards;
create policy "Members can view stamps" on public.love_stamp_cards for select using (
  exists (select 1 from public.couple_members m where m.couple_id = love_stamp_cards.couple_id and m.user_id = auth.uid())
);
drop policy if exists "Members can view missions" on public.love_daily_missions;
create policy "Members can view missions" on public.love_daily_missions for select using (
  exists (select 1 from public.couple_members m where m.couple_id = love_daily_missions.couple_id and m.user_id = auth.uid())
);

-- Existing members can read the score; only security-definer functions below can change it.
drop policy if exists "Members can update relationship score" on public.couple_relationship;
drop policy if exists "Members can create relationship score" on public.couple_relationship;

create or replace function public.is_love_admin()
returns boolean language sql stable as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false)
$$;

-- Old versions of these functions may have a different return type.
-- Drop only the matching Love Ticket function signatures, then recreate them below.
drop function if exists public.admin_grant_love_points(uuid, integer);
drop function if exists public.admin_grant_love_stamps(uuid, integer);
drop function if exists public.complete_love_daily_mission(uuid, text);
drop function if exists public.admin_create_love_coupon(uuid, text, text, text);
drop function if exists public.redeem_love_stamps(uuid, uuid);
drop function if exists public.reveal_special_love_coupon(uuid);
drop function if exists public.admin_love_overview();

create or replace function public.admin_grant_love_points(p_couple_id uuid, p_amount integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_love_admin() then raise exception 'Admin only'; end if;
  if p_amount not between 1 and 10 then raise exception 'Amount must be 1 to 10'; end if;
  update couple_state set balance = least(10, coalesce(balance,0) + p_amount) where couple_id = p_couple_id;
  if not found then insert into couple_state(couple_id,balance) values (p_couple_id,least(10,p_amount)); end if;
  insert into couple_relationship(couple_id,score,updated_at) values(p_couple_id,least(100,p_amount*5),now())
  on conflict(couple_id) do update set score=least(100,couple_relationship.score + p_amount*5),updated_at=now();
end $$;

create or replace function public.admin_grant_love_stamps(p_couple_id uuid, p_amount integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_love_admin() then raise exception 'Admin only'; end if;
  if p_amount not between 1 and 10 then raise exception 'Amount must be 1 to 10'; end if;
  insert into love_stamp_cards(couple_id,stamps,updated_at) values(p_couple_id,least(10,p_amount),now())
  on conflict(couple_id) do update set stamps=least(10,love_stamp_cards.stamps + p_amount),updated_at=now();
  insert into couple_relationship(couple_id,score,updated_at) values(p_couple_id,least(100,p_amount*10),now())
  on conflict(couple_id) do update set score=least(100,couple_relationship.score + p_amount*10),updated_at=now();
end $$;

create or replace function public.complete_love_daily_mission(p_couple_id uuid, p_mission_key text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not exists(select 1 from couple_members where couple_id=p_couple_id and user_id=auth.uid()) then raise exception 'Not a member'; end if;
  insert into love_daily_missions(couple_id,user_id,mission_key) values(p_couple_id,auth.uid(),p_mission_key);
  insert into couple_relationship(couple_id,score,updated_at) values(p_couple_id,2.5,now())
  on conflict(couple_id) do update set score=least(100,couple_relationship.score + 2.5),updated_at=now();
  return true;
exception when unique_violation then return false;
end $$;

create or replace function public.admin_create_love_coupon(p_couple_id uuid,p_title text,p_description text,p_coupon_type text default 'normal')
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if not public.is_love_admin() then raise exception 'Admin only'; end if;
  insert into coupons(couple_id,title,description,is_active,coupon_type) values(p_couple_id,p_title,p_description,true,case when p_coupon_type='special' then 'special' else 'normal' end) returning id into new_id;
  return new_id;
end $$;

create or replace function public.redeem_love_stamps(p_couple_id uuid,p_coupon_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare stamp_count integer;
begin
  if not exists(select 1 from couple_members where couple_id=p_couple_id and user_id=auth.uid()) then raise exception 'Not a member'; end if;
  select stamps into stamp_count from love_stamp_cards where couple_id=p_couple_id for update;
  if coalesce(stamp_count,0) <> 10 then raise exception 'Need 10 stamps'; end if;
  update love_stamp_cards set stamps=0,updated_at=now() where couple_id=p_couple_id;
end $$;

create or replace function public.reveal_special_love_coupon(p_coupon_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c_id uuid; b integer; st integer; rel numeric;
begin
  select couple_id into c_id from coupons where id=p_coupon_id and coupon_type='special';
  if c_id is null or not exists(select 1 from couple_members where couple_id=c_id and user_id=auth.uid()) then raise exception 'Not allowed'; end if;
  select balance into b from couple_state where couple_id=c_id;
  select stamps into st from love_stamp_cards where couple_id=c_id;
  select score into rel from couple_relationship where couple_id=c_id;
  if coalesce(b,0)<>10 or coalesce(st,0)<>10 or coalesce(rel,0)<100 then raise exception 'Requires 10 love points, 10 stamps and 100 relationship score'; end if;
  update coupons set is_revealed=true where id=p_coupon_id;
  update couple_state set balance=0 where couple_id=c_id;
  update love_stamp_cards set stamps=0,updated_at=now() where couple_id=c_id;
  update couple_relationship set score=0,updated_at=now() where couple_id=c_id;
end $$;

create or replace function public.admin_love_overview()
returns jsonb language plpgsql security definer set search_path = public,auth as $$
begin
  if not public.is_love_admin() then raise exception 'Admin only'; end if;
  return jsonb_build_object(
    'couples',(select coalesce(jsonb_agg(jsonb_build_object('couple_id',c.id,'invite_code',c.invite_code,'label',c.invite_code)), '[]'::jsonb) from couples c),
    'users',(select coalesce(jsonb_agg(jsonb_build_object('email',u.email,'role',cm.role,'couple_label',c.invite_code,'balance',coalesce(cs.balance,0))), '[]'::jsonb) from auth.users u left join couple_members cm on cm.user_id=u.id left join couples c on c.id=cm.couple_id left join couple_state cs on cs.couple_id=c.id),
    'coupons',(select coalesce(jsonb_agg(jsonb_build_object('id',cp.id,'title',cp.title,'is_active',cp.is_active,'couple_label',c.invite_code)), '[]'::jsonb) from coupons cp join couples c on c.id=cp.couple_id),
    'total_points',(select coalesce(sum(balance),0) from couple_state),
    'total_coupons',(select count(*) from coupons),
    'total_stamps',(select coalesce(sum(stamps),0) from love_stamp_cards)
  );
end $$;

grant execute on function public.admin_grant_love_points(uuid,integer),public.admin_grant_love_stamps(uuid,integer),public.complete_love_daily_mission(uuid,text),public.admin_create_love_coupon(uuid,text,text,text),public.redeem_love_stamps(uuid,uuid),public.reveal_special_love_coupon(uuid),public.admin_love_overview() to authenticated;
