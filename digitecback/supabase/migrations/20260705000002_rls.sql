-- DIGI-TEC loyalty backend: Row Level Security
--
-- Auth model:
--   * Customers authenticate via Supabase Auth phone sign-in. The verified phone
--     number is available in the JWT as the `phone` claim and is matched against
--     customers.phone (expected to be stored in the same E.164 format Supabase
--     Auth uses for phone identities).
--   * Staff authenticate via Supabase Auth (email/password or similar) and are
--     linked to a row in staff_users via staff_users.auth_user_id = auth.uid().
--
-- Helper functions are SECURITY DEFINER + STABLE so they can look up the caller's
-- identity without being blocked by the RLS they are used to enforce.

create or replace function public.current_customer_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from customers where phone = (auth.jwt() ->> 'phone') limit 1;
$$;

create or replace function public.current_staff_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role from staff_users where auth_user_id = auth.uid() limit 1;
$$;

alter table staff_users enable row level security;
alter table customers enable row level security;
alter table vehicles enable row level security;
alter table service_records enable row level security;
alter table loyalty_accounts enable row level security;
alter table loyalty_transactions enable row level security;
alter table rewards enable row level security;
alter table redemptions enable row level security;

-- ============ customers ============
-- Customer can read only their own record; staff can read all customer records.
create policy customers_select_own on customers
  for select
  using (phone = (auth.jwt() ->> 'phone'));

create policy customers_select_staff on customers
  for select
  using (public.current_staff_role() is not null);

-- Entry/manager staff create new customers during manual service entry.
create policy customers_insert_staff on customers
  for insert
  with check (public.current_staff_role() in ('entry','manager'));

-- ============ vehicles ============
create policy vehicles_select_own on vehicles
  for select
  using (customer_id = public.current_customer_id());

create policy vehicles_select_staff on vehicles
  for select
  using (public.current_staff_role() is not null);

create policy vehicles_insert_staff on vehicles
  for insert
  with check (public.current_staff_role() in ('entry','manager'));

-- ============ service_records ============
create policy service_records_select_own on service_records
  for select
  using (customer_id = public.current_customer_id());

create policy service_records_select_staff on service_records
  for select
  using (public.current_staff_role() is not null);

create policy service_records_insert_staff on service_records
  for insert
  with check (public.current_staff_role() in ('entry','manager'));

-- ============ loyalty_accounts ============
-- No direct insert/update policy for any role: balances are maintained only by
-- the SECURITY DEFINER trigger functions in the loyalty-triggers migration.
create policy loyalty_accounts_select_own on loyalty_accounts
  for select
  using (customer_id = public.current_customer_id());

create policy loyalty_accounts_select_staff on loyalty_accounts
  for select
  using (public.current_staff_role() is not null);

-- ============ loyalty_transactions ============
create policy loyalty_transactions_select_own on loyalty_transactions
  for select
  using (customer_id = public.current_customer_id());

create policy loyalty_transactions_select_staff on loyalty_transactions
  for select
  using (public.current_staff_role() is not null);

-- Manager-only manual adjustments.
create policy loyalty_transactions_insert_manager_adjustment on loyalty_transactions
  for insert
  with check (
    public.current_staff_role() = 'manager'
    and type = 'adjustment'
  );

-- ============ rewards ============
-- Catalog is readable by any authenticated customer (mobile app loyalty screen)
-- and by staff; only managers can modify it.
create policy rewards_select_customer on rewards
  for select
  using (active = true and public.current_customer_id() is not null);

create policy rewards_select_staff on rewards
  for select
  using (public.current_staff_role() is not null);

create policy rewards_insert_manager on rewards
  for insert
  with check (public.current_staff_role() = 'manager');

create policy rewards_update_manager on rewards
  for update
  using (public.current_staff_role() = 'manager')
  with check (public.current_staff_role() = 'manager');

create policy rewards_delete_manager on rewards
  for delete
  using (public.current_staff_role() = 'manager');

-- ============ redemptions ============
create policy redemptions_select_own on redemptions
  for select
  using (customer_id = public.current_customer_id());

create policy redemptions_select_staff on redemptions
  for select
  using (public.current_staff_role() is not null);

-- Redemptions are created at the desk by staff on the customer's behalf (the
-- spec disallows direct customer writes on this table); a future edge function
-- using the service role key could offer customer self-service redemption.
create policy redemptions_insert_staff on redemptions
  for insert
  with check (public.current_staff_role() in ('entry','manager'));

create policy redemptions_update_manager on redemptions
  for update
  using (public.current_staff_role() = 'manager')
  with check (public.current_staff_role() = 'manager');

-- ============ staff_users ============
-- Staff can see their own record; managers can see the whole roster.
-- No client-side insert/update/delete: staff accounts are provisioned via the
-- service role key (admin operation), not via anon/authenticated clients.
create policy staff_users_select_own on staff_users
  for select
  using (auth_user_id = auth.uid());

create policy staff_users_select_manager on staff_users
  for select
  using (public.current_staff_role() = 'manager');
