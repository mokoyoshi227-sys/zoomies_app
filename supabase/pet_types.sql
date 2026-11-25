-- Zoomies pet types (Нохой, Муур, …) managed from the admin panel's "Амьтан" tab.
-- Run AFTER admin.sql: Supabase → SQL Editor → paste → Run. Safe to run more than once.
--
--   * Everyone can read the list (the app shows it); only admins add, change, hide or delete.
--   * Hiding a type (active = false) takes it out of the pet picker and the shop filters;
--     pets people already registered with that type keep working.
--   * Deleting a type also removes it from products. It is refused while any registered pet uses it
--     (hide it instead).

create table if not exists public.pet_types (
  id         text primary key default ('t' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))
             check (id ~ '^[a-z][a-z0-9_]{1,23}$'),
  name       text not null check (char_length(name) between 1 and 30),
  photo      text check (char_length(photo) <= 500),   -- URL, or a file inside the app such as dog.png
  active     boolean not null default true,
  sort       integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists pet_types_touch on public.pet_types;
create trigger pet_types_touch before update on public.pet_types for each row execute function public.touch_updated_at();

-- the six types the app started with (their pictures ship with the app)
insert into public.pet_types (id, name, photo, sort) values
  ('dog', 'Нохой', 'dog.png', 1), ('cat', 'Муур', 'cat2.webp', 2), ('bird', 'Шувуу', 'bird.webp', 3),
  ('fish', 'Загас', 'fish.webp', 4), ('rabbit', 'Туулай', 'rabbit.webp', 5), ('hamster', 'Шишүүхэй', 'hamster.png', 6)
on conflict (id) do nothing;

alter table public.pet_types enable row level security;
drop policy if exists "pet types: everyone reads" on public.pet_types;
drop policy if exists "pet types: admin adds"    on public.pet_types;
drop policy if exists "pet types: admin edits"   on public.pet_types;
drop policy if exists "pet types: admin deletes" on public.pet_types;
create policy "pet types: everyone reads" on public.pet_types for select to anon, authenticated using (true);
create policy "pet types: admin adds"     on public.pet_types for insert to authenticated with check (public.is_admin());
create policy "pet types: admin edits"    on public.pet_types for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "pet types: admin deletes"  on public.pet_types for delete to authenticated using (public.is_admin());

-- registered pets: the fixed list becomes a link to pet_types (a used type cannot be deleted)
alter table public.pets drop constraint if exists pets_kind_check;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'pets_kind_fk') then
    alter table public.pets add constraint pets_kind_fk foreign key (kind) references public.pet_types (id) on update cascade on delete restrict;
  end if;
end $$;

-- products: every type in "pets" must exist
alter table public.products drop constraint if exists products_pets_check;
create or replace function public.products_pets_valid() returns trigger
language plpgsql set search_path = '' as $$
begin
  if exists (select 1 from unnest(new.pets) k where not exists (select 1 from public.pet_types t where t.id = k)) then
    raise exception 'unknown pet type';
  end if;
  return new;
end $$;
drop trigger if exists products_pets_valid on public.products;
create trigger products_pets_valid before insert or update of pets on public.products for each row execute function public.products_pets_valid();

-- deleting a type takes it off products first (the whole delete is undone if a registered pet still uses it)
create or replace function public.pet_types_cleanup() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.products set pets = array_remove(pets, old.id) where old.id = any (pets);
  return old;
end $$;
drop trigger if exists pet_types_cleanup on public.pet_types;
create trigger pet_types_cleanup before delete on public.pet_types for each row execute function public.pet_types_cleanup();

-- live updates to the app and the admin panel
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'pet_types') then
    alter publication supabase_realtime add table public.pet_types;
  end if;
end $$;
