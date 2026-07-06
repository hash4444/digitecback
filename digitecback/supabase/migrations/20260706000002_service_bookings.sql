-- Phase 3 (moved up): at-home service booking queue. No loyalty point
-- interaction yet -- flagged back to the requester whether at-home services
-- should earn points like in-shop service_records, since that changes the
-- trigger logic and wasn't specified.

create table service_bookings (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references customers(id) on delete cascade,
  vehicle_id uuid references vehicles(id) on delete cascade,
  service_type text not null,
  address text not null,
  requested_time timestamptz not null,
  status text not null default 'requested'
    check (status in ('requested','confirmed','in_progress','completed','cancelled')),
  technician_id uuid references staff_users(id),
  notes text,
  created_at timestamptz default now()
);

create index idx_service_bookings_customer_id on service_bookings(customer_id);
create index idx_service_bookings_vehicle_id on service_bookings(vehicle_id);
create index idx_service_bookings_technician_id on service_bookings(technician_id);

alter table service_bookings enable row level security;

-- Customer: create + read only their own bookings. No update policy at all
-- for the customer path (default-deny), matching every other table in this
-- schema where customer writes are staff/service-role only.
create policy service_bookings_insert_own on service_bookings
  for insert
  with check (customer_id = private.current_customer_id());

-- Single merged SELECT policy (own OR staff) rather than two permissive
-- policies, consistent with the multiple_permissive_policies advisor fix
-- already applied to every other table.
create policy service_bookings_select on service_bookings
  for select
  using (
    customer_id = private.current_customer_id()
    or private.current_staff_role() is not null
  );

-- Staff (entry or manager) may update rows; the column grant below is what
-- actually restricts *which* columns can change to status/technician_id --
-- the RLS policy alone only controls *which rows* they can touch.
create policy service_bookings_update_staff on service_bookings
  for update
  using (private.current_staff_role() in ('entry','manager'))
  with check (private.current_staff_role() in ('entry','manager'));

revoke update on service_bookings from authenticated;
grant update (status, technician_id) on service_bookings to authenticated;
