-- Zoomies: paid "featured" placement (Онцлох байршил) for products, vet clinics, vets and shelters.
-- Run AFTER admin.sql (and features.sql, if you use shelters): Supabase → SQL Editor → paste → Run.
-- Safe to run more than once.
--
-- How it works
--   * featured_until = the last day the place is featured (Mongolian date). Empty or past = not featured.
--   * The app shows featured ones first with an "Онцлох" label, swapping their order each time it opens,
--     and drops them back on its own once the day has passed.
--   * At most 3 featured at a time in each list (products / clinics / vets / shelters), so it stays worth paying for.
--   * Only the admin can set it: shelter staff, who may edit their own shelter, cannot feature it themselves.

alter table public.products add column if not exists featured_until date;
alter table public.clinics  add column if not exists featured_until date;
alter table public.vets     add column if not exists featured_until date;
do $$ begin
  if to_regclass('public.shelters') is not null then
    alter table public.shelters add column if not exists featured_until date;
  end if;
end $$;

create or replace function public.featured_guard() returns trigger
language plpgsql set search_path = '' as $$
declare
  today date := (now() at time zone 'Asia/Ulaanbaatar')::date;
  n     integer;
begin
  if tg_op = 'UPDATE' and new.featured_until is not distinct from old.featured_until then return new; end if;
  if tg_op = 'INSERT' and new.featured_until is null then return new; end if;
  if not public.is_admin() then raise exception 'featured: admins only'; end if;
  if new.featured_until is null or new.featured_until < today then return new; end if;
  execute format('select count(*) from %I.%I where featured_until >= $1 and id <> $2', tg_table_schema, tg_table_name)
    into n using today, new.id;
  if n >= 3 then raise exception 'featured limit: at most 3 featured at a time'; end if;
  return new;
end $$;

drop trigger if exists featured_guard on public.products;
drop trigger if exists featured_guard on public.clinics;
drop trigger if exists featured_guard on public.vets;
create trigger featured_guard before insert or update of featured_until on public.products for each row execute function public.featured_guard();
create trigger featured_guard before insert or update of featured_until on public.clinics  for each row execute function public.featured_guard();
create trigger featured_guard before insert or update of featured_until on public.vets     for each row execute function public.featured_guard();
do $$ begin
  if to_regclass('public.shelters') is not null then
    drop trigger if exists featured_guard on public.shelters;
    create trigger featured_guard before insert or update of featured_until on public.shelters for each row execute function public.featured_guard();
  end if;
end $$;
