-- Zoomies bonus stars, kept and checked on the server.
-- Run AFTER orders.sql: Supabase → SQL Editor → paste → Run. Safe to run more than once.
--
-- Rules (the same ones the app shows)
--   * Every account starts with 4 stars.
--   * Each order earns max(1, floor(total / 10,000)) stars.
--   * Stars are spent in steps of 10; 1 star = 1,000₮ off the goods (never off delivery).
--   * A cancelled order gives back the stars it used and takes back the stars it earned.
--   * The balance is worked out from the orders themselves, so a phone can never give itself stars.

alter table public.orders add column if not exists stars_used     integer not null default 0 check (stars_used >= 0 and stars_used % 10 = 0);
alter table public.orders add column if not exists stars_discount integer not null default 0 check (stars_discount >= 0);
alter table public.orders add column if not exists stars_earned   integer not null default 0 check (stars_earned >= 0);

-- orders placed before this file get the stars they earned (once: only rows still at 0)
update public.orders set stars_earned = greatest(1, total / 10000) where stars_earned = 0;

-- balance of the signed-in account
create or replace function public.my_stars() returns integer
language sql stable security definer set search_path = '' as $$
  select 4 + coalesce(sum(o.stars_earned - o.stars_used), 0)::integer
  from public.orders o
  where o.user_id = auth.uid() and o.status <> 'cancelled'
$$;
revoke execute on function public.my_stars() from public, anon;
grant  execute on function public.my_stars() to authenticated;

-- place_order with an optional p_stars (0 = no stars). Older app versions that do not send it keep working.
drop function if exists public.place_order(jsonb, text, text, text, text);
create or replace function public.place_order(p_items jsonb, p_address text, p_phone text, p_payment text, p_note text default null, p_stars integer default 0)
returns public.orders
language plpgsql security definer set search_path = '' as $$
declare
  it      jsonb;
  prod    public.products;
  lines   jsonb := '[]'::jsonb;
  sub     integer := 0;
  q       integer;
  disc    integer;
  ship    integer;
  stars   integer := coalesce(p_stars, 0);
  have    integer;
  sdisc   integer;
  earned  integer;
  who     public.profiles;
  o       public.orders;
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  if p_payment not in ('cod', 'transfer', 'qpay') then raise exception 'unknown payment method'; end if;
  if char_length(trim(coalesce(p_address, ''))) < 3 then raise exception 'address required'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'bad items'; end if;
  if jsonb_array_length(p_items) not between 1 and 50 then raise exception 'bad items'; end if;
  if stars < 0 or stars % 10 <> 0 then raise exception 'stars must be a multiple of 10'; end if;

  -- one order at a time per account, so two taps cannot spend the same stars twice
  perform pg_advisory_xact_lock(hashtext('zoomies-order-' || auth.uid()::text));

  for it in select * from jsonb_array_elements(p_items) loop
    q := (it ->> 'qty')::integer;
    if q is null or q not between 1 and 99 then raise exception 'bad quantity'; end if;
    select * into prod from public.products where id = it ->> 'id' and active;
    if not found then raise exception 'product unavailable: %', it ->> 'id'; end if;
    lines := lines || jsonb_build_object('id', prod.id, 'name', prod.name, 'price', prod.price, 'qty', q);
    sub := sub + prod.price * q;
  end loop;

  -- 10% off the first order (rounded to 100₮); free delivery from 50,000₮, otherwise 5,000₮
  disc := case when exists (select 1 from public.orders where user_id = auth.uid() and status <> 'cancelled') then 0
               else (round(sub * 0.1 / 100.0) * 100)::integer end;
  ship := case when sub >= 50000 then 0 else 5000 end;

  if stars > 0 then
    have := public.my_stars();
    if stars > have then raise exception 'not enough stars'; end if;
    if stars * 1000 > sub - disc then raise exception 'stars exceed order'; end if;
  end if;
  sdisc  := stars * 1000;
  earned := greatest(1, (sub - disc - sdisc + ship) / 10000);

  select * into who from public.profiles where id = auth.uid();
  insert into public.orders (user_id, customer_name, phone, address, note, items, subtotal, discount, shipping, total, payment_method,
                             stars_used, stars_discount, stars_earned)
  values (auth.uid(), coalesce(who.name, '—'), coalesce(nullif(trim(p_phone), ''), who.phone, ''), left(trim(p_address), 300),
          nullif(left(trim(coalesce(p_note, '')), 300), ''), lines, sub, disc, ship, sub - disc - sdisc + ship, p_payment,
          stars, sdisc, earned)
  returning * into o;
  return o;
end $$;
revoke execute on function public.place_order(jsonb, text, text, text, text, integer) from public, anon;
grant  execute on function public.place_order(jsonb, text, text, text, text, integer) to authenticated;
