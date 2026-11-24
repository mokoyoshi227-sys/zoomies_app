-- Zoomies database (Supabase / Postgres 15+)
-- Paste the whole file into Supabase → SQL Editor → Run. It is safe to run on an empty project.
--
-- Privacy model
--   * Every table has Row Level Security on. The app only ever holds the publishable (anon) key,
--     so these rules are what keeps one user's data away from another.
--   * A user sees and edits only their own profile, pets, health logs and memos.
--   * Other people's pets are read only through two functions that return a "pet card"
--     (name, kind, sex, birth date, breed, weight, photo, owner's first name) and nothing else:
--       pet_card_by_code(code) – for someone who opened a share link
--       pet_cards(ids)         – for pets linked to yours by a friend request
--   * Friend requests are created and answered only through functions, so the rules
--     (you own the pet, no duplicates, reverse request = instant friendship) cannot be skipped.

-- ───────────────────────── profiles ─────────────────────────
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 40),
  phone       text check (phone ~ '^[0-9 ]{8,9}$'),          -- never shown to other users
  avatar_path text,                                          -- path in the private 'avatars' bucket
  created_at  timestamptz not null default now()
);
alter table public.profiles enable row level security;
create policy "own profile: read"   on public.profiles for select to authenticated using (id = (select auth.uid()));
create policy "own profile: update" on public.profiles for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- a profile row is made automatically when someone signs up (name/phone come from sign-up metadata)
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles (id, name, phone)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'name'), ''), 'Zoomies'), 40),
    -- keep the phone only if it looks right, so a bad value never blocks the sign-up itself
    case when trim(new.raw_user_meta_data ->> 'phone') ~ '^[0-9 ]{8,9}$' then trim(new.raw_user_meta_data ->> 'phone') end
  );
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ───────────────────────── pets ─────────────────────────
-- 10-character share code from an alphabet without look-alikes (no 0/O, 1/I): ~50 random bits.
-- Bytes come from gen_random_uuid(); byte 6 is skipped because it holds the UUID version bits.
create or replace function public.new_share_code() returns text
language sql volatile set search_path = '' as $$
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + (get_byte(b, i) % 32), 1), '' order by i)
  from (select decode(replace(gen_random_uuid()::text, '-', ''), 'hex') as b) s,
       unnest(array[0, 1, 2, 3, 4, 5, 7, 9, 10, 11]) as i
$$;

create table public.pets (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind        text not null check (kind in ('dog', 'cat', 'bird', 'fish', 'rabbit', 'hamster')),
  name        text not null check (char_length(name) between 1 and 24),
  sex         text check (sex in ('Эр', 'Эм')),
  birth       date,
  breed       text check (char_length(breed) <= 30),
  weight      numeric(5, 2) check (weight > 0 and weight < 1000),
  photo_path  text,                                          -- path in the public 'pet-photos' bucket
  share_code  text not null unique default public.new_share_code(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index pets_owner_idx on public.pets (owner_id);
alter table public.pets enable row level security;
create policy "own pets: read"   on public.pets for select to authenticated using (owner_id = (select auth.uid()));
create policy "own pets: add"    on public.pets for insert to authenticated with check (owner_id = (select auth.uid()));
create policy "own pets: update" on public.pets for update to authenticated using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));
create policy "own pets: delete" on public.pets for delete to authenticated using (owner_id = (select auth.uid()));

-- the server, not the app, decides the owner and the share code; neither can be changed later
create or replace function public.pets_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.owner_id   := auth.uid();
    new.share_code := public.new_share_code();
  else
    new.owner_id   := old.owner_id;
    new.share_code := old.share_code;
    new.updated_at := now();
  end if;
  return new;
end $$;
create trigger pets_guard before insert or update on public.pets
  for each row execute function public.pets_guard();

-- ───────────────────────── friend requests ─────────────────────────
-- One row per pair of pets. pending → accepted / declined. Deleting the row = unfriend / cancel.
create table public.friend_requests (
  id           uuid primary key default gen_random_uuid(),
  from_pet     uuid not null references public.pets (id) on delete cascade,
  to_pet       uuid not null references public.pets (id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  check (from_pet <> to_pet)
);
-- at most one live (pending or accepted) link per pair, whichever direction it was sent
create unique index friend_pair_live on public.friend_requests (least(from_pet, to_pet), greatest(from_pet, to_pet))
  where status in ('pending', 'accepted');
create index friend_to_idx on public.friend_requests (to_pet);
create index friend_from_idx on public.friend_requests (from_pet);
alter table public.friend_requests enable row level security;
-- either side may see the row and delete it (cancel a request, decline-and-forget, or unfriend: gone for both)
create policy "my pets' requests: read" on public.friend_requests for select to authenticated using (
  exists (select 1 from public.pets p where p.id in (from_pet, to_pet) and p.owner_id = (select auth.uid()))
);
create policy "my pets' requests: delete" on public.friend_requests for delete to authenticated using (
  exists (select 1 from public.pets p where p.id in (from_pet, to_pet) and p.owner_id = (select auth.uid()))
);
-- no insert/update policies: requests go through the functions below

-- send a request from one of my pets to the pet behind a share code.
-- returns: 'sent' | 'accepted' (they had already asked us) | 'pending' (already asked) | 'already' (friends) | 'not_found' | 'self'
create or replace function public.send_friend_request(my_pet uuid, code text) returns text
language plpgsql security definer set search_path = '' as $$
declare
  target uuid;
  live   public.friend_requests;
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  if not exists (select 1 from public.pets where id = my_pet and owner_id = auth.uid()) then
    raise exception 'not your pet';
  end if;
  select id into target from public.pets where share_code = upper(trim(code));
  if target is null then return 'not_found'; end if;
  if target = my_pet then return 'self'; end if;

  select * into live from public.friend_requests
   where least(from_pet, to_pet) = least(my_pet, target)
     and greatest(from_pet, to_pet) = greatest(my_pet, target)
     and status in ('pending', 'accepted')
   limit 1;
  if found then
    if live.status = 'accepted' then return 'already'; end if;
    if live.to_pet = my_pet then
      update public.friend_requests set status = 'accepted', responded_at = now() where id = live.id;
      return 'accepted';
    end if;
    return 'pending';
  end if;

  insert into public.friend_requests (from_pet, to_pet) values (my_pet, target);
  return 'sent';
end $$;

-- answer a request sent to one of my pets
create or replace function public.respond_friend_request(req uuid, accept boolean) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  update public.friend_requests r
     set status = case when accept then 'accepted' else 'declined' end, responded_at = now()
   where r.id = req and r.status = 'pending'
     and exists (select 1 from public.pets p where p.id = r.to_pet and p.owner_id = auth.uid());
  return found;
end $$;

-- ───────────────────────── pet cards (the only view of other people's pets) ─────────────────────────
-- anyone, even signed out, can open a share link
create or replace function public.pet_card_by_code(code text)
returns table (id uuid, kind text, name text, sex text, birth date, breed text, weight numeric, photo_path text, owner_name text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.kind, p.name, p.sex, p.birth, p.breed, p.weight, p.photo_path, split_part(pr.name, ' ', 1)
    from public.pets p join public.profiles pr on pr.id = p.owner_id
   where p.share_code = upper(trim(code))
$$;

-- cards for my own pets and for pets linked to mine by a pending or accepted request
create or replace function public.pet_cards(ids uuid[])
returns table (id uuid, kind text, name text, sex text, birth date, breed text, weight numeric, photo_path text, owner_name text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.kind, p.name, p.sex, p.birth, p.breed, p.weight, p.photo_path, split_part(pr.name, ' ', 1)
    from public.pets p join public.profiles pr on pr.id = p.owner_id
   where p.id = any (ids)
     and (
       p.owner_id = auth.uid()
       or exists (
         select 1 from public.friend_requests r
           join public.pets mine on mine.id in (r.from_pet, r.to_pet) and mine.owner_id = auth.uid()
          where p.id in (r.from_pet, r.to_pet) and r.status in ('pending', 'accepted')
       )
     )
$$;

-- functions are callable by PUBLIC by default; narrow that down
revoke execute on function public.send_friend_request(uuid, text)      from public, anon;
revoke execute on function public.respond_friend_request(uuid, boolean) from public, anon;
revoke execute on function public.pet_cards(uuid[])                     from public, anon;
revoke execute on function public.handle_new_user()                     from public, anon, authenticated;
revoke execute on function public.pets_guard()                          from public, anon, authenticated;
grant  execute on function public.send_friend_request(uuid, text)      to authenticated;
grant  execute on function public.respond_friend_request(uuid, boolean) to authenticated;
grant  execute on function public.pet_cards(uuid[])                     to authenticated;
grant  execute on function public.pet_card_by_code(text)                to anon, authenticated;

-- ───────────────────────── health log ─────────────────────────
-- dates are plain calendar dates (no time zone), exactly as the app stores them today
create table public.health_logs (
  id         uuid primary key default gen_random_uuid(),
  pet_id     uuid not null references public.pets (id) on delete cascade,
  type       text not null check (type in ('food', 'walk', 'med', 'vaccine')),
  log_date   date not null,
  log_time   time,
  amount_g   integer check (amount_g > 0),
  minutes    integer check (minutes > 0),
  km         numeric(6, 2) check (km >= 0),
  name       text check (char_length(name) <= 40),
  dose       text check (char_length(dose) <= 30),
  due        date,
  note       text check (char_length(note) <= 80),
  created_at timestamptz not null default now(),
  check ((type = 'food' and amount_g is not null)
      or (type = 'walk' and minutes is not null)
      or (type in ('med', 'vaccine') and name is not null)),
  check (due is null or (type = 'vaccine' and due > log_date))
);
create index health_pet_date_idx on public.health_logs (pet_id, log_date);
alter table public.health_logs enable row level security;
create policy "own pets' logs" on public.health_logs for all to authenticated
  using      (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())));

-- ───────────────────────── memos ─────────────────────────
create table public.memos (
  id         uuid primary key default gen_random_uuid(),
  pet_id     uuid not null references public.pets (id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 200),
  done       boolean not null default false,
  done_date  date,
  added_on   date not null,
  created_at timestamptz not null default now()
);
create index memos_pet_idx on public.memos (pet_id);
alter table public.memos enable row level security;
create policy "own pets' memos" on public.memos for all to authenticated
  using      (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())));

-- ───────────────────────── photo storage ─────────────────────────
-- pet-photos: public, so a share card can show the photo to someone not signed in.
--             Files live at <user id>/<random>.jpg, so their addresses cannot be guessed or listed.
-- avatars:    private; only the user themselves can read their own face photo.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('pet-photos', 'pet-photos', true,  1048576, array['image/jpeg', 'image/png', 'image/webp']),
  ('avatars',    'avatars',    false,  524288, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy "photos: upload to own folder" on storage.objects for insert to authenticated
  with check (bucket_id in ('pet-photos', 'avatars') and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "photos: replace own" on storage.objects for update to authenticated
  using      (bucket_id in ('pet-photos', 'avatars') and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id in ('pet-photos', 'avatars') and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "photos: delete own" on storage.objects for delete to authenticated
  using (bucket_id in ('pet-photos', 'avatars') and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "photos: read own" on storage.objects for select to authenticated
  using (bucket_id in ('pet-photos', 'avatars') and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ───────────────────────── live updates ─────────────────────────
-- friend requests show up in the app's bell the moment they are sent (Realtime respects the policies above)
alter publication supabase_realtime add table public.friend_requests;
