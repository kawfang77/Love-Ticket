-- Run this once in Supabase Dashboard > SQL Editor.
-- It adds only the diary, relationship-score, and image-storage features.

create table if not exists public.couple_relationship (
  couple_id uuid primary key references public.couples(id) on delete cascade,
  score integer not null default 0 check (score >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.love_diary_entries (
  id uuid primary key default gen_random_uuid(),
  couple_id uuid not null references public.couples(id) on delete cascade,
  author_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 100),
  place text,
  entry_date date not null default current_date,
  note text,
  image_url text,
  created_at timestamptz not null default now()
);

alter table public.couple_relationship enable row level security;
alter table public.love_diary_entries enable row level security;

create policy "Members can view relationship score" on public.couple_relationship
for select using (exists (select 1 from public.couple_members m where m.couple_id = couple_relationship.couple_id and m.user_id = auth.uid()));
create policy "Members can create relationship score" on public.couple_relationship
for insert with check (exists (select 1 from public.couple_members m where m.couple_id = couple_relationship.couple_id and m.user_id = auth.uid()));
create policy "Members can update relationship score" on public.couple_relationship
for update using (exists (select 1 from public.couple_members m where m.couple_id = couple_relationship.couple_id and m.user_id = auth.uid()));

create policy "Members can view shared diary" on public.love_diary_entries
for select using (exists (select 1 from public.couple_members m where m.couple_id = love_diary_entries.couple_id and m.user_id = auth.uid()));
create policy "Members can add shared diary" on public.love_diary_entries
for insert with check (auth.uid() = author_id and exists (select 1 from public.couple_members m where m.couple_id = love_diary_entries.couple_id and m.user_id = auth.uid()));

insert into storage.buckets (id, name, public) values ('love-diary', 'love-diary', true)
on conflict (id) do nothing;

create policy "Members can upload diary photos" on storage.objects
for insert to authenticated with check (bucket_id = 'love-diary' and (storage.foldername(name))[1] in (select couple_id::text from public.couple_members where user_id = auth.uid()));
create policy "Anyone can view diary photos" on storage.objects
for select using (bucket_id = 'love-diary');

-- Designate the requested account as the Love Ticket administrator.
update auth.users
set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
where id = 'd1ae4d14-9ecc-435d-a239-ad65d8314f1e';
