-- Zoomies admin: catalog (products, vet clinics, vets) managed from the admin panel (admin/index.html).
-- Run AFTER schema.sql: Supabase → SQL Editor → paste this whole file → Run.
--
-- Who can do what
--   * Everyone (even signed out) can READ the catalog, so the app can show it. Hidden items
--     (active = false) are read too but the app does not show them; nothing in these tables is private.
--   * Only accounts listed in public.admins can add, change or delete anything, or upload catalog photos.
--     The admin list itself cannot be read or changed through the API at all; only here, in the SQL Editor.
--   * Changes reach every open app within a second (Realtime).

-- ───────────────────────── the admin list ─────────────────────────
create table public.admins (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security; -- no policies: invisible to the API

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;
grant execute on function public.is_admin() to anon, authenticated;

create or replace function public.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end $$;

-- ───────────────────────── products ─────────────────────────
create table public.products (
  id          text primary key default ('p' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10)),
  name        text not null check (char_length(name) between 1 and 60),
  description text not null default '' check (char_length(description) <= 500),
  price       integer not null check (price >= 0 and price < 100000000),          -- төгрөг
  pets        text[] not null default '{}' check (pets <@ array['dog', 'cat', 'bird', 'fish', 'rabbit', 'hamster']),
  is_new      boolean not null default false,
  photo       text check (char_length(photo) <= 500),                              -- URL, or a path inside the app such as photos/x.png
  art         jsonb,                                                               -- drawn picture used when there is no photo
  active      boolean not null default true,                                       -- false = hidden in the app
  sort        integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger products_touch before update on public.products for each row execute function public.touch_updated_at();

-- ───────────────────────── vet clinics ─────────────────────────
create table public.clinics (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 80),
  phone       text check (char_length(phone) <= 40),
  address     text check (char_length(address) <= 200),
  district    text check (char_length(district) <= 60),
  hours       text check (char_length(hours) <= 100),
  services    text[] not null default '{}',
  description text not null default '' check (char_length(description) <= 800),
  lat         double precision check (lat between -90 and 90),
  lng         double precision check (lng between -180 and 180),
  photo       text check (char_length(photo) <= 500),
  active      boolean not null default true,
  sort        integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create trigger clinics_touch before update on public.clinics for each row execute function public.touch_updated_at();

-- ───────────────────────── vets ─────────────────────────
create table public.vets (
  id          uuid primary key default gen_random_uuid(),
  clinic_id   uuid references public.clinics (id) on delete set null,
  name        text not null check (char_length(name) between 1 and 80),
  specialty   text check (char_length(specialty) <= 80),
  phone       text check (char_length(phone) <= 40),
  bio         text not null default '' check (char_length(bio) <= 800),
  photo       text check (char_length(photo) <= 500),
  active      boolean not null default true,
  sort        integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index vets_clinic_idx on public.vets (clinic_id);
create trigger vets_touch before update on public.vets for each row execute function public.touch_updated_at();

-- ───────────────────────── access rules ─────────────────────────
alter table public.products enable row level security;
alter table public.clinics  enable row level security;
alter table public.vets     enable row level security;
create policy "catalog: everyone reads" on public.products for select to anon, authenticated using (true);
create policy "catalog: everyone reads" on public.clinics  for select to anon, authenticated using (true);
create policy "catalog: everyone reads" on public.vets     for select to anon, authenticated using (true);
create policy "catalog: admin adds"    on public.products for insert to authenticated with check (public.is_admin());
create policy "catalog: admin adds"    on public.clinics  for insert to authenticated with check (public.is_admin());
create policy "catalog: admin adds"    on public.vets     for insert to authenticated with check (public.is_admin());
create policy "catalog: admin edits"   on public.products for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "catalog: admin edits"   on public.clinics  for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "catalog: admin edits"   on public.vets     for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "catalog: admin deletes" on public.products for delete to authenticated using (public.is_admin());
create policy "catalog: admin deletes" on public.clinics  for delete to authenticated using (public.is_admin());
create policy "catalog: admin deletes" on public.vets     for delete to authenticated using (public.is_admin());

-- ───────────────────────── catalog photos ─────────────────────────
-- public bucket: the app shows these to everyone; only the admin can upload, replace or delete
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('catalog', 'catalog', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;
create policy "catalog photos: admin uploads" on storage.objects for insert to authenticated
  with check (bucket_id = 'catalog' and public.is_admin());
create policy "catalog photos: admin replaces" on storage.objects for update to authenticated
  using (bucket_id = 'catalog' and public.is_admin()) with check (bucket_id = 'catalog' and public.is_admin());
create policy "catalog photos: admin deletes" on storage.objects for delete to authenticated
  using (bucket_id = 'catalog' and public.is_admin());
create policy "catalog photos: admin lists" on storage.objects for select to authenticated
  using (bucket_id = 'catalog' and public.is_admin());

-- ───────────────────────── live updates ─────────────────────────
alter publication supabase_realtime add table public.products, public.clinics, public.vets;

-- ───────────────────────── starting catalog: the 12 products from products.json ─────────────────────────
insert into public.products (id, name, description, price, pets, is_new, photo, art, sort) values
  ('p1',  'Дугуй муурын аяга', 'Керамик аяга, гулсдаггүй ёроолтой. Багтаамж 350 мл. Аяга угаагчинд угааж болно.', 24900, '{cat}', true, 'photos/cat-bowl-round.png', '["bowl","#F26B12","#FF9A55",true]', 1),
  ('p2',  'Гаа ногоон аяга', 'Хоёр давхар ханатай, дулаан тогтоодог. Жижиг нохой, мууранд тохиромжтой. 500 мл.', 29900, '{cat,dog}', true, null, '["bowl","#CFE6D2","#E4F3E6",false]', 2),
  ('p3',  'Судалтай хулгана', 'Зөөлөн нэхмэл тоглоом, дотроо муурын өвстэй. Муурыг идэвхтэй байлгана.', 9900, '{cat}', false, null, '["mouse"]', 3),
  ('p4',  'Тахиатай хуурай хоол · 3 кг', 'Насанд хүрсэн нохойд. Тахианы мах 28%, үр тариагүй. Нэг уут дунд нохойд ойролцоогоор 3 долоо хоног хүрнэ.', 68900, '{dog}', true, null, '["bag","#0F4C17","#F26B12"]', 4),
  ('p5',  'Олсон тоглоом', 'Хөвөн олсоор хийсэн, шүд цэвэрлэхэд тусална. Татаж тоглоход бат бөх.', 15900, '{dog}', false, null, '["rope"]', 5),
  ('p6',  'Хүзүүвч ба оосор', 'Тохируулгатай хүзүүвч (30–45 см), 1.5 м урттай оосор. Шөнө гэрэл ойлгоно.', 32500, '{dog}', false, null, '["leash"]', 6),
  ('p7',  'Муурны элс · 10 л', 'Бөөгнөрдөг бентонит элс, үнэр шингээгчтэй. 10 литр нэг муурд 4 долоо хоног хүрнэ.', 21500, '{cat}', false, null, '["bag","#5B8DB8","#5B8DB8"]', 7),
  ('p8',  'Үрийн холимог · 1 кг', 'Тоть, шар шувуунд зориулсан шар будаа, наранцэцгийн үр, овъёосны холимог.', 12900, '{bird}', true, null, '["bag","#E7B53B","#B8860B"]', 8),
  ('p9',  'Загасны ширхэгт хоол', 'Халуун усны загасанд. Усыг булингартуулдаггүй. 100 г.', 8900, '{fish}', false, null, '["can","#2F8FD0"]', 9),
  ('p10', 'Шинэ өвс · 1 кг', 'Хуурай, тоосгүй тимофей өвс. Туулай, шишүүхэйн шүд, хоол боловсруулалтад тустай.', 14500, '{rabbit,hamster}', false, null, '["bag","#6DAF4E","#3E7D2A"]', 10),
  ('p11', 'Чимээгүй гүйлтийн дугуй', 'Шөнө чимээ гаргадаггүй холхивчтой, 21 см голчтой. Тор руу бэхэлнэ.', 27900, '{hamster}', true, null, '["wheel"]', 11),
  ('p12', 'Лууван зажлуур', 'Байгалийн модоор хийсэн зажлах тоглоом. Шүдийг хэт ургахаас сэргийлнэ.', 7900, '{rabbit}', false, null, '["carrot"]', 12)
on conflict (id) do nothing;

-- ───────────────────────── make yourself the only admin ─────────────────────────
-- Replace ТАНЫ_ИМЭЙЛ with the email you sign in to Zoomies with (keep the quotes), then run.
-- You must already have a Zoomies account with that email.
insert into public.admins (user_id)
select id from auth.users where lower(email) = lower('ТАНЫ_ИМЭЙЛ')
on conflict do nothing;

-- check: this should list exactly one email, yours
select u.email as admin_email from public.admins a join auth.users u on u.id = a.user_id;
