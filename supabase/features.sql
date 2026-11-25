-- Zoomies: food stock reminders, vet appointments, QR pet tags (lost & found), adoption with shelter logins,
-- and the push-notification plumbing they share.
-- Run AFTER schema.sql, admin.sql, orders.sql, stars.sql and pet_types.sql:
-- Supabase → SQL Editor → paste this whole file → Run. Safe to run more than once.
-- Push notifications also need the "push" Edge Function and one settings line (see supabase/README.md).

-- ═════════════════════════ 0. shared helpers ═════════════════════════
create schema if not exists private;                -- not exposed through the API
revoke all on schema private from public, anon, authenticated;
create table if not exists private.settings (key text primary key, value text not null);

create extension if not exists pg_net;              -- outgoing HTTP (to the push Edge Function)

-- today in Mongolia (the server clock is UTC)
create or replace function public.mn_today() returns date
language sql stable set search_path = '' as $$ select (now() at time zone 'Asia/Ulaanbaatar')::date $$;

-- queue one push notification for one person; quietly does nothing until push is set up
create or replace function private.push(p_user uuid, p_title text, p_body text, p_url text default './', p_tag text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare u text; s text;
begin
  if p_user is null then return; end if;
  select value into u from private.settings where key = 'push_url';
  select value into s from private.settings where key = 'hook_secret';
  if u is null or s is null then return; end if;
  if not exists (select 1 from public.push_subscriptions where user_id = p_user) then return; end if;
  perform net.http_post(
    url     := u,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-zoomies-hook', s),
    body    := jsonb_build_object('user_id', p_user, 'title', p_title, 'body', p_body, 'url', coalesce(p_url, './'), 'tag', p_tag)
  );
exception when others then null;                    -- a notification must never break the change that caused it
end $$;

-- ═════════════════════════ 1. push subscriptions (one per phone / browser) ═════════════════════════
create table if not exists public.push_subscriptions (
  endpoint   text primary key check (char_length(endpoint) <= 1000),
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  p256dh     text not null check (char_length(p256dh) <= 200),
  auth       text not null check (char_length(auth) <= 100),
  created_at timestamptz not null default now()
);
create index if not exists push_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
drop policy if exists "push: own" on public.push_subscriptions;
create policy "push: own" on public.push_subscriptions for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
-- the same phone signing in as someone else takes the subscription over
create or replace function public.save_push(p_endpoint text, p_p256dh text, p_auth text) returns void
language sql security definer set search_path = '' as $$
  insert into public.push_subscriptions (endpoint, user_id, p256dh, auth) values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth
$$;
revoke execute on function public.save_push(text, text, text) from public, anon;
grant  execute on function public.save_push(text, text, text) to authenticated;

-- ═════════════════════════ 2. roles: admins and shelter staff ═════════════════════════
create table if not exists public.shelters (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 80),
  phone       text check (char_length(phone) <= 40),
  district    text check (char_length(district) <= 60),
  address     text check (char_length(address) <= 200),
  description text not null default '' check (char_length(description) <= 800),
  photo       text check (char_length(photo) <= 500),
  active      boolean not null default true,
  sort        integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
drop trigger if exists shelters_touch on public.shelters;
create trigger shelters_touch before update on public.shelters for each row execute function public.touch_updated_at();

create table if not exists public.shelter_staff (
  user_id    uuid primary key references auth.users (id) on delete cascade,  -- one shelter per account
  shelter_id uuid not null references public.shelters (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.shelter_staff enable row level security;   -- no policies: read through the functions below

create or replace function public.my_shelter() returns uuid
language sql stable security definer set search_path = '' as $$ select shelter_id from public.shelter_staff where user_id = auth.uid() $$;
create or replace function public.is_staff_of(p_shelter uuid) returns boolean
language sql stable security definer set search_path = '' as $$ select exists (select 1 from public.shelter_staff where user_id = auth.uid() and shelter_id = p_shelter) $$;
-- what the admin panel may show to the signed-in account
create or replace function public.my_role() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('admin', public.is_admin(), 'shelter', s.id, 'shelter_name', s.name)
  from (select 1) x left join public.shelter_staff ss on ss.user_id = auth.uid() left join public.shelters s on s.id = ss.shelter_id
$$;
-- admins add / remove shelter staff by the email they signed up to Zoomies with
create or replace function public.admin_add_staff(p_email text, p_shelter uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare u uuid;
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  select id into u from auth.users where lower(email) = lower(trim(p_email));
  if u is null then return 'no_user'; end if;
  insert into public.shelter_staff (user_id, shelter_id) values (u, p_shelter)
  on conflict (user_id) do update set shelter_id = excluded.shelter_id;
  return 'added';
end $$;
create or replace function public.admin_remove_staff(p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  delete from public.shelter_staff where user_id = p_user;
end $$;
create or replace function public.admin_staff() returns table (user_id uuid, email text, shelter_id uuid)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  return query select ss.user_id, u.email::text, ss.shelter_id from public.shelter_staff ss join auth.users u on u.id = ss.user_id order by u.email;
end $$;
revoke execute on function public.my_shelter(), public.is_staff_of(uuid), public.my_role(), public.admin_add_staff(text, uuid), public.admin_remove_staff(uuid), public.admin_staff() from public, anon;
grant  execute on function public.my_shelter(), public.is_staff_of(uuid), public.my_role(), public.admin_add_staff(text, uuid), public.admin_remove_staff(uuid), public.admin_staff() to authenticated;

alter table public.shelters enable row level security;
drop policy if exists "shelters: everyone reads" on public.shelters;
drop policy if exists "shelters: admin adds"     on public.shelters;
drop policy if exists "shelters: admin or staff edits" on public.shelters;
drop policy if exists "shelters: admin deletes"  on public.shelters;
create policy "shelters: everyone reads" on public.shelters for select to anon, authenticated using (true);
create policy "shelters: admin adds"     on public.shelters for insert to authenticated with check (public.is_admin());
create policy "shelters: admin or staff edits" on public.shelters for update to authenticated
  using (public.is_admin() or public.is_staff_of(id)) with check (public.is_admin() or public.is_staff_of(id));
create policy "shelters: admin deletes"  on public.shelters for delete to authenticated using (public.is_admin());

-- ═════════════════════════ 3. adoption ═════════════════════════
create table if not exists public.adoptions (
  id          uuid primary key default gen_random_uuid(),
  shelter_id  uuid not null references public.shelters (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 40),
  kind        text not null references public.pet_types (id) on update cascade,
  sex         text check (sex in ('Эр', 'Эм')),
  age         text check (char_length(age) <= 30),                -- "2 нас", "6 сар"
  breed       text check (char_length(breed) <= 40),
  description text not null default '' check (char_length(description) <= 1000),
  photo       text check (char_length(photo) <= 500),
  vaccinated  boolean not null default false,
  sterilized  boolean not null default false,
  status      text not null default 'available' check (status in ('available', 'reserved', 'adopted')),
  active      boolean not null default true,
  sort        integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists adoptions_shelter_idx on public.adoptions (shelter_id);
drop trigger if exists adoptions_touch on public.adoptions;
create trigger adoptions_touch before update on public.adoptions for each row execute function public.touch_updated_at();
alter table public.adoptions enable row level security;
drop policy if exists "adoptions: everyone reads"  on public.adoptions;
drop policy if exists "adoptions: admin or staff" on public.adoptions;
create policy "adoptions: everyone reads"  on public.adoptions for select to anon, authenticated using (true);
create policy "adoptions: admin or staff" on public.adoptions for all to authenticated
  using (public.is_admin() or public.is_staff_of(shelter_id)) with check (public.is_admin() or public.is_staff_of(shelter_id));

create table if not exists public.adoption_requests (
  id          uuid primary key default gen_random_uuid(),
  adoption_id uuid not null references public.adoptions (id) on delete cascade,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 40),
  phone       text not null check (phone ~ '^[0-9 +]{8,15}$'),
  message     text not null default '' check (char_length(message) <= 500),
  status      text not null default 'new' check (status in ('new', 'contacted', 'approved', 'declined')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists adoption_req_idx on public.adoption_requests (adoption_id);
create unique index if not exists adoption_req_once on public.adoption_requests (adoption_id, user_id) where status in ('new', 'contacted');
drop trigger if exists adoption_requests_touch on public.adoption_requests;
create trigger adoption_requests_touch before update on public.adoption_requests for each row execute function public.touch_updated_at();
alter table public.adoption_requests enable row level security;
drop policy if exists "adoption requests: send"  on public.adoption_requests;
drop policy if exists "adoption requests: read"  on public.adoption_requests;
drop policy if exists "adoption requests: answer" on public.adoption_requests;
drop policy if exists "adoption requests: withdraw" on public.adoption_requests;
create policy "adoption requests: send" on public.adoption_requests for insert to authenticated
  with check (user_id = (select auth.uid()) and status = 'new'
              and exists (select 1 from public.adoptions a where a.id = adoption_id and a.active and a.status <> 'adopted'));
create policy "adoption requests: read" on public.adoption_requests for select to authenticated using (
  user_id = (select auth.uid()) or public.is_admin()
  or exists (select 1 from public.adoptions a where a.id = adoption_id and public.is_staff_of(a.shelter_id)));
create policy "adoption requests: answer" on public.adoption_requests for update to authenticated
  using (public.is_admin() or exists (select 1 from public.adoptions a where a.id = adoption_id and public.is_staff_of(a.shelter_id)))
  with check (public.is_admin() or exists (select 1 from public.adoptions a where a.id = adoption_id and public.is_staff_of(a.shelter_id)));
create policy "adoption requests: withdraw" on public.adoption_requests for delete to authenticated using (user_id = (select auth.uid()));

-- shelter staff may upload adoption photos into catalog/adoptions/ (admins already may upload anywhere in catalog)
drop policy if exists "catalog photos: shelter staff uploads" on storage.objects;
drop policy if exists "catalog photos: shelter staff deletes" on storage.objects;
create policy "catalog photos: shelter staff uploads" on storage.objects for insert to authenticated
  with check (bucket_id = 'catalog' and (storage.foldername(name))[1] in ('adoptions', 'shelters') and public.my_shelter() is not null);
create policy "catalog photos: shelter staff deletes" on storage.objects for delete to authenticated
  using (bucket_id = 'catalog' and (storage.foldername(name))[1] in ('adoptions', 'shelters') and public.my_shelter() is not null);

-- ═════════════════════════ 4. vet appointments ═════════════════════════
alter table public.clinics add column if not exists booking      boolean not null default true;
alter table public.clinics add column if not exists open_time    time    not null default '09:00';
alter table public.clinics add column if not exists close_time   time    not null default '18:00';
alter table public.clinics add column if not exists slot_minutes integer not null default 30 check (slot_minutes between 10 and 240);

create table if not exists public.appointments (
  id         uuid primary key default gen_random_uuid(),
  number     bigint generated always as identity (start with 101) unique,
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  clinic_id  uuid not null references public.clinics (id) on delete cascade,
  vet_id     uuid references public.vets (id) on delete set null,
  pet_id     uuid references public.pets (id) on delete set null,
  pet_name   text not null check (char_length(pet_name) between 1 and 24),
  pet_kind   text,
  customer   text not null,
  phone      text not null check (phone ~ '^[0-9 +]{8,15}$'),
  day        date not null,
  at         time not null,
  reason     text not null default '' check (char_length(reason) <= 300),
  status     text not null default 'requested' check (status in ('requested', 'confirmed', 'cancelled', 'done')),
  note       text check (char_length(note) <= 300),           -- from the clinic
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists appointments_user_idx on public.appointments (user_id, day);
create index if not exists appointments_day_idx on public.appointments (day, at);
-- one live booking per clinic / vet / time
create unique index if not exists appointments_slot on public.appointments
  (clinic_id, coalesce(vet_id, '00000000-0000-0000-0000-000000000000'::uuid), day, at) where status in ('requested', 'confirmed');
drop trigger if exists appointments_touch on public.appointments;
create trigger appointments_touch before update on public.appointments for each row execute function public.touch_updated_at();
alter table public.appointments enable row level security;
drop policy if exists "appointments: own or admin reads" on public.appointments;
drop policy if exists "appointments: admin changes"      on public.appointments;
create policy "appointments: own or admin reads" on public.appointments for select to authenticated using (user_id = (select auth.uid()) or public.is_admin());
create policy "appointments: admin changes"      on public.appointments for update to authenticated using (public.is_admin()) with check (public.is_admin());
-- no insert/delete policies: book_appointment() and cancel_appointment() below

-- free times for a clinic (and vet) on a day; "taken" ones are left out
create or replace function public.free_slots(p_clinic uuid, p_vet uuid, p_day date) returns setof time
language plpgsql stable security definer set search_path = '' as $$
declare c public.clinics; t time; now_mn timestamp := (now() at time zone 'Asia/Ulaanbaatar');
begin
  select * into c from public.clinics where id = p_clinic and active and booking;
  if not found or p_day < public.mn_today() or p_day > public.mn_today() + 60 then return; end if;
  t := c.open_time;
  while t + make_interval(mins => c.slot_minutes) <= c.close_time loop
    if (p_day + t) > now_mn + interval '30 minutes'
       and not exists (select 1 from public.appointments a where a.clinic_id = p_clinic and a.day = p_day and a.at = t
                         and a.status in ('requested', 'confirmed')
                         and (p_vet is null or a.vet_id is null or a.vet_id = p_vet)) then
      return next t;
    end if;
    t := t + make_interval(mins => c.slot_minutes);
  end loop;
end $$;

create or replace function public.book_appointment(p_clinic uuid, p_vet uuid, p_pet uuid, p_day date, p_at time, p_reason text, p_phone text)
returns public.appointments
language plpgsql security definer set search_path = '' as $$
declare p public.pets; who public.profiles; a public.appointments;
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  select * into p from public.pets where id = p_pet and owner_id = auth.uid();
  if not found then raise exception 'not your pet'; end if;
  if p_vet is not null and not exists (select 1 from public.vets where id = p_vet and clinic_id = p_clinic and active) then raise exception 'vet not at clinic'; end if;
  if not exists (select 1 from public.free_slots(p_clinic, p_vet, p_day) s where s = p_at) then raise exception 'slot taken'; end if;
  if (select count(*) from public.appointments where user_id = auth.uid() and status = 'requested') >= 5 then raise exception 'too many requests'; end if;
  select * into who from public.profiles where id = auth.uid();
  insert into public.appointments (user_id, clinic_id, vet_id, pet_id, pet_name, pet_kind, customer, phone, day, at, reason)
  values (auth.uid(), p_clinic, p_vet, p.id, p.name, p.kind, coalesce(who.name, '—'), coalesce(nullif(trim(p_phone), ''), who.phone, ''), p_day, p_at, left(coalesce(trim(p_reason), ''), 300))
  returning * into a;
  return a;
exception when unique_violation then raise exception 'slot taken';
end $$;

create or replace function public.cancel_appointment(p_id uuid) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  update public.appointments set status = 'cancelled' where id = p_id and user_id = auth.uid() and status in ('requested', 'confirmed');
  return found;
end $$;
revoke execute on function public.free_slots(uuid, uuid, date), public.book_appointment(uuid, uuid, uuid, date, time, text, text), public.cancel_appointment(uuid) from public, anon;
grant  execute on function public.free_slots(uuid, uuid, date), public.book_appointment(uuid, uuid, uuid, date, time, text, text), public.cancel_appointment(uuid) to authenticated;

-- ═════════════════════════ 5. QR pet tags: lost & found ═════════════════════════
alter table public.pets add column if not exists tag_code  text unique default public.new_share_code();
alter table public.pets add column if not exists lost      boolean not null default false;
alter table public.pets add column if not exists lost_note text check (char_length(lost_note) <= 200);
alter table public.pets add column if not exists lost_since timestamptz;
alter table public.pets add column if not exists tag_phone boolean not null default false;  -- owner chooses to show their phone on the tag page
update public.pets set tag_code = public.new_share_code() where tag_code is null;

-- the owner, share code and tag code are set by the server; marking lost stamps the time
create or replace function public.pets_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.owner_id   := auth.uid();
    new.share_code := public.new_share_code();
    new.tag_code   := public.new_share_code();
    new.lost_since := case when new.lost then now() end;
  else
    new.owner_id   := old.owner_id;
    new.share_code := old.share_code;
    new.tag_code   := old.tag_code;
    new.updated_at := now();
    if new.lost and not old.lost then new.lost_since := now(); elsif not new.lost then new.lost_since := null; end if;
  end if;
  return new;
end $$;

-- what someone who scanned the collar sees (no address, no email; the phone only if the owner allowed it)
create or replace function public.tag_card(code text)
returns table (kind text, name text, sex text, breed text, photo_path text, lost boolean, lost_note text, lost_since timestamptz, owner_name text, owner_phone text)
language sql stable security definer set search_path = '' as $$
  select p.kind, p.name, p.sex, p.breed, p.photo_path, p.lost, p.lost_note, p.lost_since, split_part(pr.name, ' ', 1),
         case when p.tag_phone then pr.phone end
    from public.pets p join public.profiles pr on pr.id = p.owner_id
   where p.tag_code = upper(trim(code))
$$;

create table if not exists public.found_reports (
  id         uuid primary key default gen_random_uuid(),
  pet_id     uuid not null references public.pets (id) on delete cascade,
  message    text not null default '' check (char_length(message) <= 500),
  contact    text not null default '' check (char_length(contact) <= 60),
  lat        double precision check (lat between -90 and 90),
  lng        double precision check (lng between -180 and 180),
  seen       boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists found_pet_idx on public.found_reports (pet_id, created_at desc);
alter table public.found_reports enable row level security;
drop policy if exists "found: owner or admin reads" on public.found_reports;
drop policy if exists "found: owner marks seen"     on public.found_reports;
drop policy if exists "found: owner or admin deletes" on public.found_reports;
create policy "found: owner or admin reads" on public.found_reports for select to authenticated
  using (public.is_admin() or exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())));
create policy "found: owner marks seen" on public.found_reports for update to authenticated
  using (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())));
create policy "found: owner or admin deletes" on public.found_reports for delete to authenticated
  using (public.is_admin() or exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())));

-- anyone (signed in or not) who scanned the tag can tell the owner; at most 5 messages per pet per hour
create or replace function public.report_found(code text, p_message text, p_contact text, p_lat double precision, p_lng double precision)
returns text language plpgsql security definer set search_path = '' as $$
declare p public.pets;
begin
  select * into p from public.pets where tag_code = upper(trim(code));
  if not found then return 'not_found'; end if;
  if (select count(*) from public.found_reports where pet_id = p.id and created_at > now() - interval '1 hour') >= 5 then return 'busy'; end if;
  insert into public.found_reports (pet_id, message, contact, lat, lng)
  values (p.id, left(coalesce(trim(p_message), ''), 500), left(coalesce(trim(p_contact), ''), 60),
          case when p_lat between -90 and 90 then p_lat end, case when p_lng between -180 and 180 then p_lng end);
  return 'sent';
end $$;
revoke execute on function public.tag_card(text), public.report_found(text, text, text, double precision, double precision) from public;
grant  execute on function public.tag_card(text), public.report_found(text, text, text, double precision, double precision) to anon, authenticated;

-- admin panel: finders' messages and pets marked lost (name and owner's first name only)
create or replace function public.admin_found()
returns table (id uuid, pet_id uuid, pet_name text, pet_kind text, owner_name text, message text, contact text, lat double precision, lng double precision, seen boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  return query select f.id, f.pet_id, p.name, p.kind, split_part(pr.name, ' ', 1), f.message, f.contact, f.lat, f.lng, f.seen, f.created_at
    from public.found_reports f join public.pets p on p.id = f.pet_id join public.profiles pr on pr.id = p.owner_id
   order by f.created_at desc limit 300;
end $$;
create or replace function public.admin_lost()
returns table (id uuid, name text, kind text, owner_name text, lost_note text, lost_since timestamptz, tag_code text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_admin() then raise exception 'admins only'; end if;
  return query select p.id, p.name, p.kind, split_part(pr.name, ' ', 1), p.lost_note, p.lost_since, p.tag_code
    from public.pets p join public.profiles pr on pr.id = p.owner_id where p.lost order by p.lost_since desc nulls last;
end $$;
revoke execute on function public.admin_found(), public.admin_lost() from public, anon;
grant  execute on function public.admin_found(), public.admin_lost() to authenticated;

-- ═════════════════════════ 6. food stock (when will the bag run out?) ═════════════════════════
alter table public.products add column if not exists pack_g integer check (pack_g is null or pack_g between 50 and 100000);  -- food bag size in grams

create table if not exists public.food_stocks (
  pet_id      uuid primary key references public.pets (id) on delete cascade,   -- one open bag per pet
  product_id  text references public.products (id) on delete set null,
  product_name text not null check (char_length(product_name) between 1 and 60),
  pack_g      integer not null check (pack_g between 50 and 100000),
  opened      date not null,
  reminded_on date,
  updated_at  timestamptz not null default now()
);
alter table public.food_stocks enable row level security;
drop policy if exists "food stock: own" on public.food_stocks;
create policy "food stock: own" on public.food_stocks for all to authenticated
  using      (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())))
  with check (exists (select 1 from public.pets p where p.id = pet_id and p.owner_id = (select auth.uid())));

-- grams left and days left for every open bag: average of the last 7 days that have a food entry
create or replace function private.food_outlook()
returns table (pet_id uuid, owner_id uuid, pet_name text, product_id text, product_name text, grams_left integer, days_left integer)
language sql stable security definer set search_path = '' as $$
  select f.pet_id, p.owner_id, p.name, f.product_id, f.product_name,
         greatest(0, f.pack_g - coalesce(used.g, 0))::integer,
         case when coalesce(rate.per_day, 0) > 0 then floor(greatest(0, f.pack_g - coalesce(used.g, 0)) / rate.per_day)::integer end
    from public.food_stocks f
    join public.pets p on p.id = f.pet_id
    left join lateral (select sum(h.amount_g) g from public.health_logs h where h.pet_id = f.pet_id and h.type = 'food' and h.log_date >= f.opened) used on true
    left join lateral (select sum(h.amount_g)::numeric / nullif(count(distinct h.log_date), 0) per_day
                         from public.health_logs h where h.pet_id = f.pet_id and h.type = 'food' and h.log_date > public.mn_today() - 7) rate on true
$$;

-- ═════════════════════════ 7. notifications: triggers and the daily reminder run ═════════════════════════
create or replace function private.on_order_status() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status is distinct from old.status then
    perform private.push(new.user_id,
      case new.status when 'paid' then 'Төлбөр баталгаажлаа' when 'delivering' then 'Захиалга хүргэлтэд гарлаа'
                      when 'done' then 'Захиалга хүргэгдлээ' when 'cancelled' then 'Захиалга цуцлагдлаа' else 'Захиалга шинэчлэгдлээ' end,
      '#' || new.number || ' · ' || to_char(new.total, 'FM999,999,999') || '₮', './', 'order-' || new.id);
  end if;
  return null;
end $$;
drop trigger if exists push_order_status on public.orders;
create trigger push_order_status after update of status on public.orders for each row execute function private.on_order_status();

create or replace function private.on_appointment_status() returns trigger
language plpgsql security definer set search_path = '' as $$
declare cn text;
begin
  if new.status is distinct from old.status and new.status in ('confirmed', 'cancelled') then
    select name into cn from public.clinics where id = new.clinic_id;
    perform private.push(new.user_id,
      case new.status when 'confirmed' then 'Цаг баталгаажлаа' else 'Цаг цуцлагдлаа' end,
      new.pet_name || ' · ' || coalesce(cn, '') || ' · ' || to_char(new.day, 'MM.DD') || ' ' || to_char(new.at, 'HH24:MI'), './#vets', 'appt-' || new.id);
  end if;
  return null;
end $$;
drop trigger if exists push_appointment_status on public.appointments;
create trigger push_appointment_status after update of status on public.appointments for each row execute function private.on_appointment_status();

create or replace function private.on_found_report() returns trigger
language plpgsql security definer set search_path = '' as $$
declare p public.pets;
begin
  select * into p from public.pets where id = new.pet_id;
  perform private.push(p.owner_id, p.name || '-г олсон хүн мэдэгдлээ!', coalesce(nullif(new.message, ''), 'QR хүзүүвчийг уншуулсан байна.'), './#qr', 'found-' || p.id);
  return null;
end $$;
drop trigger if exists push_found_report on public.found_reports;
create trigger push_found_report after insert on public.found_reports for each row execute function private.on_found_report();

create or replace function private.on_adoption_request() returns trigger
language plpgsql security definer set search_path = '' as $$
declare a public.adoptions; s record;
begin
  select * into a from public.adoptions where id = new.adoption_id;
  if tg_op = 'INSERT' then
    for s in select user_id from public.shelter_staff where shelter_id = a.shelter_id loop
      perform private.push(s.user_id, 'Шинэ үрчлэх хүсэлт', new.name || ' · ' || a.name, './admin/', 'adopt-req-' || new.id);
    end loop;
  elsif new.status is distinct from old.status and new.status in ('contacted', 'approved', 'declined') then
    perform private.push(new.user_id,
      case new.status when 'approved' then a.name || '-г үрчлэх хүсэлт зөвшөөрөгдлөө' when 'declined' then a.name || '-г үрчлэх хүсэлт татгалзагдлаа'
                      else 'Асрамжийн газар тантай холбогдоно' end,
      a.name, './#adopt', 'adopt-' || new.id);
  end if;
  return null;
end $$;
drop trigger if exists push_adoption_request on public.adoption_requests;
create trigger push_adoption_request after insert or update of status on public.adoption_requests for each row execute function private.on_adoption_request();

-- every morning (10:00 Mongolia): food running low, vaccines due soon, tomorrow's appointments
create or replace function private.daily_reminders() returns void
language plpgsql security definer set search_path = '' as $$
declare r record; lead integer := 5;
begin
  for r in select * from private.food_outlook() o where o.days_left is not null and o.days_left <= lead loop
    if not exists (select 1 from public.food_stocks f where f.pet_id = r.pet_id and f.reminded_on = public.mn_today()) then
      perform private.push(r.owner_id, r.pet_name || '-ийн хоол ' || case when r.days_left <= 0 then 'дуусчээ' else r.days_left || ' хоногийн дараа дуусна' end,
        r.product_name || ' · Нэг товчоор дахин захиалаарай', './#shop', 'food-' || r.pet_id);
      update public.food_stocks set reminded_on = public.mn_today() where pet_id = r.pet_id;
    end if;
  end loop;
  for r in select distinct on (h.pet_id, h.name) p.owner_id, p.name pet_name, h.name vac, h.due
             from public.health_logs h join public.pets p on p.id = h.pet_id
            where h.type = 'vaccine' and h.due between public.mn_today() and public.mn_today() + 3
            order by h.pet_id, h.name, h.due loop
    perform private.push(r.owner_id, r.pet_name || ': вакцины хугацаа ойртлоо', r.vac || ' · ' || to_char(r.due, 'MM.DD'), './', 'vac-' || r.pet_name || r.vac);
  end loop;
  for r in select a.user_id, a.pet_name, a.at, c.name clinic from public.appointments a join public.clinics c on c.id = a.clinic_id
            where a.status = 'confirmed' and a.day = public.mn_today() + 1 loop
    perform private.push(r.user_id, 'Маргааш эмчийн цагтай', r.pet_name || ' · ' || r.clinic || ' · ' || to_char(r.at, 'HH24:MI'), './#vets', null);
  end loop;
end $$;

-- the schedule itself (pg_cron); harmless if cron is not available on the project
do $$ begin
  create extension if not exists pg_cron;
  perform cron.unschedule(jobid) from cron.job where jobname = 'zoomies-daily';
  perform cron.schedule('zoomies-daily', '0 2 * * *', 'select private.daily_reminders()');
exception when others then raise notice 'pg_cron not available: daily reminders are off (%)', sqlerrm;
end $$;

-- ═════════════════════════ 8. live updates ═════════════════════════
do $$
declare t text;
begin
  foreach t in array array['appointments', 'found_reports', 'adoptions', 'adoption_requests', 'shelters', 'food_stocks'] loop
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;
