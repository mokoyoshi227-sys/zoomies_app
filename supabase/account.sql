-- Zoomies: let a user delete their own account from inside the app (App Store and Google Play require this).
-- Run once: Supabase → SQL Editor → paste → Run. Safe to run again.
--
-- What goes when the account is deleted (all through "on delete cascade" set up in schema.sql / admin.sql):
--   auth.users row → profiles → pets → health_logs, memos, friend_requests (on both sides) → admins (if any)
-- Photo files are removed by the app through the Storage API just before this is called
-- (Supabase does not allow deleting storage files with SQL).

create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'sign in first'; end if;
  delete from auth.users where id = auth.uid();
end $$;

revoke execute on function public.delete_my_account() from public, anon;
grant  execute on function public.delete_my_account() to authenticated;
