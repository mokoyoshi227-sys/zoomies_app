-- Zoomies orders: customers place orders from the app, the admin sees them live in the admin panel.
-- Run AFTER schema.sql and admin.sql: Supabase → SQL Editor → paste → Run.
--
-- Safety
--   * Orders are created only by place_order(): it reads the real prices from public.products and works out
--     the discount and delivery fee itself, so a changed price on someone's phone has no effect.
--   * A customer sees only their own orders. The admin sees all of them and is the only one who can change
--     their status (new → paid → delivering → done, or cancelled).
--   * Realtime: a new order, or a status change, reaches the admin panel (and the customer) within a second.
--   * When a customer deletes their account, their orders go with it (as the privacy policy says).

create table public.orders (
  id             uuid primary key default gen_random_uuid(),
  number         bigint generated always as identity (start with 1001) unique,    -- shown to people: #1001
  user_id        uuid not null default auth.uid() references auth.users (id) on delete cascade,
  customer_name  text not null,
  phone          text not null,
  address        text not null check (char_length(address) between 3 and 300),
  note           text check (char_length(note) <= 300),
  items          jsonb not null,                                                   -- [{id, name, price, qty}] at order time
  subtotal       integer not null,
  discount       integer not null default 0,
  shipping       integer not null default 0,
  total          integer not null check (total >= 0),
  payment_method text not null check (payment_method in ('cod', 'transfer', 'qpay')),
  status         text not null default 'new' check (status in ('new', 'paid', 'delivering', 'done', 'cancelled')),
  paid_at        timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index orders_user_idx on public.orders (user_id, created_at desc);
create index orders_status_idx on public.orders (status, created_at desc);

alter table public.orders enable row level security;
create policy "orders: own or admin reads" on public.orders for select to authenticated
  using (user_id = (select auth.uid()) or public.is_admin());
create policy "orders: admin changes" on public.orders for update to authenticated
  using (public.is_admin()) with check (public.is_admin());
-- no insert/delete policies: orders are created by place_order() only, and kept as records

-- the time it was paid is stamped automatically
create or replace function public.orders_touch() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  if new.status = 'paid' and old.status is distinct from 'paid' and new.paid_at is null then new.paid_at := now(); end if;
  return new;
end $$;
create trigger orders_touch before update on public.orders for each row execute function public.orders_touch();

-- place an order: p_items = [{"id":"p1","qty":2}, …]
create or replace function public.place_order(p_items jsonb, p_address text, p_phone text, p_payment text, p_note text default null)
returns public.orders
language plpgsql security definer set search_path = '' as $$
declare
  it    jsonb;
  prod  public.products;
  lines jsonb := '[]'::jsonb;
  sub   integer := 0;
  q     integer;
  disc  integer;
  ship  integer;
  who   public.profiles;
  o     public.orders;
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  if p_payment not in ('cod', 'transfer', 'qpay') then raise exception 'unknown payment method'; end if;
  if char_length(trim(coalesce(p_address, ''))) < 3 then raise exception 'address required'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'bad items'; end if;
  if jsonb_array_length(p_items) not between 1 and 50 then raise exception 'bad items'; end if;

  for it in select * from jsonb_array_elements(p_items) loop
    q := (it ->> 'qty')::integer;
    if q is null or q not between 1 and 99 then raise exception 'bad quantity'; end if;
    select * into prod from public.products where id = it ->> 'id' and active;
    if not found then raise exception 'product unavailable: %', it ->> 'id'; end if;
    lines := lines || jsonb_build_object('id', prod.id, 'name', prod.name, 'price', prod.price, 'qty', q);
    sub := sub + prod.price * q;
  end loop;

  -- 10% off the first order (rounded to 100₮); free delivery from 50,000₮, otherwise 5,000₮ — same rules the app shows
  disc := case when exists (select 1 from public.orders where user_id = auth.uid() and status <> 'cancelled') then 0
               else (round(sub * 0.1 / 100.0) * 100)::integer end;
  ship := case when sub >= 50000 then 0 else 5000 end;

  select * into who from public.profiles where id = auth.uid();
  insert into public.orders (user_id, customer_name, phone, address, note, items, subtotal, discount, shipping, total, payment_method)
  values (auth.uid(), coalesce(who.name, '—'), coalesce(nullif(trim(p_phone), ''), who.phone, ''), left(trim(p_address), 300),
          nullif(left(trim(coalesce(p_note, '')), 300), ''), lines, sub, disc, ship, sub - disc + ship, p_payment)
  returning * into o;
  return o;
end $$;
revoke execute on function public.place_order(jsonb, text, text, text, text) from public, anon;
grant  execute on function public.place_order(jsonb, text, text, text, text) to authenticated;

alter publication supabase_realtime add table public.orders;
