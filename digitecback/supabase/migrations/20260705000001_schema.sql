-- DIGI-TEC loyalty backend: core schema
-- Order matters: staff_users must exist before service_records (FK entered_by).

create extension if not exists pgcrypto;

-- Staff users (created first: referenced by service_records.entered_by)
create table staff_users (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  role text not null check (role in ('entry','manager')),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  created_at timestamptz default now()
);

create index idx_staff_users_auth_user_id on staff_users(auth_user_id);

-- Customers
create table customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text unique not null,
  email text,
  created_at timestamptz default now()
);

create index idx_customers_phone on customers(phone);

-- Vehicles
create table vehicles (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references customers(id) on delete cascade,
  make text,
  model text,
  plate text,
  year int,
  created_at timestamptz default now()
);

create index idx_vehicles_customer_id on vehicles(customer_id);
create index idx_vehicles_plate on vehicles(plate);

-- Service records
create table service_records (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid references vehicles(id) on delete cascade,
  customer_id uuid references customers(id) on delete cascade,
  service_type text not null,
  description text,
  cost numeric(10,2) not null,
  date date not null default current_date,
  entered_by uuid references staff_users(id),
  source text not null default 'manual' check (source in ('manual','csv_import','api')),
  created_at timestamptz default now()
);

create index idx_service_records_vehicle_id on service_records(vehicle_id);
create index idx_service_records_customer_id on service_records(customer_id);
create index idx_service_records_date on service_records(date);

-- Loyalty accounts
create table loyalty_accounts (
  customer_id uuid primary key references customers(id) on delete cascade,
  points_balance int not null default 0,
  tier text not null default 'standard',
  updated_at timestamptz default now()
);

-- Loyalty transactions (audit trail)
create table loyalty_transactions (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references customers(id) on delete cascade,
  points int not null,
  type text not null check (type in ('earn','redeem','adjustment')),
  related_service_id uuid references service_records(id),
  note text,
  date timestamptz default now()
);

create index idx_loyalty_transactions_customer_id on loyalty_transactions(customer_id);

-- Rewards catalog
create table rewards (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  points_cost int not null,
  description text,
  active boolean default true,
  created_at timestamptz default now()
);

-- Redemptions
create table redemptions (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references customers(id) on delete cascade,
  reward_id uuid references rewards(id),
  date timestamptz default now(),
  status text not null default 'pending' check (status in ('pending','fulfilled','cancelled'))
);

create index idx_redemptions_customer_id on redemptions(customer_id);
create index idx_redemptions_reward_id on redemptions(reward_id);
