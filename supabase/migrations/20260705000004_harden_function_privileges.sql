-- Harden function privileges flagged by the Supabase security advisor:
-- SECURITY DEFINER functions in the `public` schema are auto-exposed by
-- PostgREST as callable RPC endpoints. Move the RLS helper functions into a
-- non-exposed `private` schema (still callable from policies, since that's a
-- direct SQL reference, not a PostgREST route) and revoke direct EXECUTE on
-- the trigger functions, which should only ever run via the trigger engine.

create schema if not exists private;

create or replace function private.current_customer_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from public.customers where phone = (auth.jwt() ->> 'phone') limit 1;
$$;

create or replace function private.current_staff_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from public.staff_users where auth_user_id = auth.uid() limit 1;
$$;

revoke execute on function private.current_customer_id() from public;
revoke execute on function private.current_staff_role() from public;
grant execute on function private.current_customer_id() to authenticated;
grant execute on function private.current_staff_role() to authenticated;

-- customers
drop policy customers_select_staff on customers;
create policy customers_select_staff on customers for select using (private.current_staff_role() is not null);
drop policy customers_insert_staff on customers;
create policy customers_insert_staff on customers for insert with check (private.current_staff_role() in ('entry','manager'));

-- vehicles
drop policy vehicles_select_own on vehicles;
create policy vehicles_select_own on vehicles for select using (customer_id = private.current_customer_id());
drop policy vehicles_select_staff on vehicles;
create policy vehicles_select_staff on vehicles for select using (private.current_staff_role() is not null);
drop policy vehicles_insert_staff on vehicles;
create policy vehicles_insert_staff on vehicles for insert with check (private.current_staff_role() in ('entry','manager'));

-- service_records
drop policy service_records_select_own on service_records;
create policy service_records_select_own on service_records for select using (customer_id = private.current_customer_id());
drop policy service_records_select_staff on service_records;
create policy service_records_select_staff on service_records for select using (private.current_staff_role() is not null);
drop policy service_records_insert_staff on service_records;
create policy service_records_insert_staff on service_records for insert with check (private.current_staff_role() in ('entry','manager'));

-- loyalty_accounts
drop policy loyalty_accounts_select_own on loyalty_accounts;
create policy loyalty_accounts_select_own on loyalty_accounts for select using (customer_id = private.current_customer_id());
drop policy loyalty_accounts_select_staff on loyalty_accounts;
create policy loyalty_accounts_select_staff on loyalty_accounts for select using (private.current_staff_role() is not null);

-- loyalty_transactions
drop policy loyalty_transactions_select_own on loyalty_transactions;
create policy loyalty_transactions_select_own on loyalty_transactions for select using (customer_id = private.current_customer_id());
drop policy loyalty_transactions_select_staff on loyalty_transactions;
create policy loyalty_transactions_select_staff on loyalty_transactions for select using (private.current_staff_role() is not null);
drop policy loyalty_transactions_insert_manager_adjustment on loyalty_transactions;
create policy loyalty_transactions_insert_manager_adjustment on loyalty_transactions
  for insert with check (private.current_staff_role() = 'manager' and type = 'adjustment');

-- rewards
drop policy rewards_select_customer on rewards;
create policy rewards_select_customer on rewards for select using (active = true and private.current_customer_id() is not null);
drop policy rewards_select_staff on rewards;
create policy rewards_select_staff on rewards for select using (private.current_staff_role() is not null);
drop policy rewards_insert_manager on rewards;
create policy rewards_insert_manager on rewards for insert with check (private.current_staff_role() = 'manager');
drop policy rewards_update_manager on rewards;
create policy rewards_update_manager on rewards for update using (private.current_staff_role() = 'manager') with check (private.current_staff_role() = 'manager');
drop policy rewards_delete_manager on rewards;
create policy rewards_delete_manager on rewards for delete using (private.current_staff_role() = 'manager');

-- redemptions
drop policy redemptions_select_own on redemptions;
create policy redemptions_select_own on redemptions for select using (customer_id = private.current_customer_id());
drop policy redemptions_select_staff on redemptions;
create policy redemptions_select_staff on redemptions for select using (private.current_staff_role() is not null);
drop policy redemptions_insert_staff on redemptions;
create policy redemptions_insert_staff on redemptions for insert with check (private.current_staff_role() in ('entry','manager'));
drop policy redemptions_update_manager on redemptions;
create policy redemptions_update_manager on redemptions for update using (private.current_staff_role() = 'manager') with check (private.current_staff_role() = 'manager');

-- staff_users
drop policy staff_users_select_manager on staff_users;
create policy staff_users_select_manager on staff_users for select using (private.current_staff_role() = 'manager');

-- Old public-schema helper functions are no longer referenced by any policy.
drop function if exists public.current_customer_id();
drop function if exists public.current_staff_role();

-- Trigger functions must never be called directly (they rely on the trigger's
-- implicit NEW record); lock down direct RPC/EXECUTE access entirely.
revoke execute on function public.award_loyalty_points() from public;
revoke execute on function public.process_redemption() from public;
