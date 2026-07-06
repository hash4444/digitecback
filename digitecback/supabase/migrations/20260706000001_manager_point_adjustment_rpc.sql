-- Fixes a gap noted in BACKEND.md: managers could previously only insert an
-- audit row into loyalty_transactions (via loyalty_transactions_insert_manager_adjustment)
-- with no path that actually moved loyalty_accounts.points_balance. This RPC
-- does both atomically, with the manager check enforced *inside* the function
-- body -- SECURITY DEFINER execution bypasses table RLS entirely, so RLS
-- cannot be relied on to gate who may call this.
--
-- Deviation from the "put it in private schema" instruction: private.* is
-- deliberately NOT in the API's exposed-schemas list (that's why
-- current_customer_id/current_staff_role live there -- to keep them off the
-- public RPC surface). A function meant to be invoked from a client via
-- supabase.rpc() must live in an exposed schema to be reachable at all, so
-- this one is public.adjust_loyalty_points. It's still locked down: EXECUTE
-- is revoked from anon and granted only to authenticated, and the manager
-- check happens on every call regardless of who holds the authenticated JWT.

create or replace function public.adjust_loyalty_points(
  p_customer_id uuid,
  p_points int,
  p_note text
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- `is distinct from` (not `<>`) so a non-staff caller -- for whom
  -- current_staff_role() returns NULL -- is still rejected instead of the
  -- comparison silently evaluating to NULL/false and falling through.
  if private.current_staff_role() is distinct from 'manager' then
    raise exception 'Only managers may adjust loyalty points';
  end if;

  insert into loyalty_transactions (customer_id, points, type, note)
  values (p_customer_id, p_points, 'adjustment', p_note);

  -- Upsert (not bare update) so an adjustment still works even if the
  -- customer has no loyalty_accounts row yet (no prior service_records).
  insert into loyalty_accounts (customer_id, points_balance, updated_at)
  values (p_customer_id, p_points, now())
  on conflict (customer_id) do update
    set points_balance = loyalty_accounts.points_balance + excluded.points_balance,
        updated_at = now();

  if (select points_balance from loyalty_accounts where customer_id = p_customer_id) < 0 then
    raise exception 'Adjustment would result in negative balance';
  end if;
end;
$$;

revoke execute on function public.adjust_loyalty_points(uuid, int, text) from public, anon, authenticated;
grant execute on function public.adjust_loyalty_points(uuid, int, text) to authenticated;
