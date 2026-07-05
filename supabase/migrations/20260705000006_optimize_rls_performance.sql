-- Performance advisor fixes:
--  * auth_rls_initplan: wrap direct auth.jwt()/auth.uid() calls in a scalar
--    subselect so Postgres evaluates them once per statement, not per row.
--  * multiple_permissive_policies: merge the "own" and "staff" SELECT
--    policies on each table into a single OR'd policy per table.
--  * unindexed_foreign_keys: add covering indexes for entered_by and
--    related_service_id.

-- customers
drop policy customers_select_own on customers;
drop policy customers_select_staff on customers;
create policy customers_select on customers
  for select
  using (
    phone = ((select auth.jwt()) ->> 'phone')
    or private.current_staff_role() is not null
  );

-- vehicles
drop policy vehicles_select_own on vehicles;
drop policy vehicles_select_staff on vehicles;
create policy vehicles_select on vehicles
  for select
  using (
    customer_id = private.current_customer_id()
    or private.current_staff_role() is not null
  );

-- service_records
drop policy service_records_select_own on service_records;
drop policy service_records_select_staff on service_records;
create policy service_records_select on service_records
  for select
  using (
    customer_id = private.current_customer_id()
    or private.current_staff_role() is not null
  );

-- loyalty_accounts
drop policy loyalty_accounts_select_own on loyalty_accounts;
drop policy loyalty_accounts_select_staff on loyalty_accounts;
create policy loyalty_accounts_select on loyalty_accounts
  for select
  using (
    customer_id = private.current_customer_id()
    or private.current_staff_role() is not null
  );

-- loyalty_transactions
drop policy loyalty_transactions_select_own on loyalty_transactions;
drop policy loyalty_transactions_select_staff on loyalty_transactions;
create policy loyalty_transactions_select on loyalty_transactions
  for select
  using (
    customer_id = private.current_customer_id()
    or private.current_staff_role() is not null
  );

-- rewards
drop policy rewards_select_customer on rewards;
drop policy rewards_select_staff on rewards;
create policy rewards_select on rewards
  for select
  using (
    (active = true and private.current_customer_id() is not null)
    or private.current_staff_role() is not null
  );

-- redemptions
drop policy redemptions_select_own on redemptions;
drop policy redemptions_select_staff on redemptions;
create policy redemptions_select on redemptions
  for select
  using (
    customer_id = private.current_customer_id()
    or private.current_staff_role() is not null
  );

-- staff_users
drop policy staff_users_select_own on staff_users;
drop policy staff_users_select_manager on staff_users;
create policy staff_users_select on staff_users
  for select
  using (
    auth_user_id = (select auth.uid())
    or private.current_staff_role() = 'manager'
  );

-- missing covering indexes for foreign keys
create index idx_service_records_entered_by on service_records(entered_by);
create index idx_loyalty_transactions_related_service_id on loyalty_transactions(related_service_id);
