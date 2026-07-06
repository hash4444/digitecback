-- DIGI-TEC loyalty backend: sample/test data.
-- Mirrors the data seeded into the live project during backend validation.
-- Safe to re-run against a fresh local `supabase db reset` (idempotent within
-- a clean database; will conflict on unique phone/plate if run twice against
-- a database that already has this data).

insert into customers (name, phone, email) values
  ('Ahmed Al Maktoum', '+971501234567', 'ahmed@example.com'),
  ('Fatima Noor', '+971502345678', 'fatima@example.com'),
  ('Youssef Hariri', '+971503456789', 'youssef@example.com');

insert into vehicles (customer_id, make, model, plate, year) values
  ((select id from customers where phone = '+971501234567'), 'Bentley', 'Continental GT', 'DXB-A12345', 2022),
  ((select id from customers where phone = '+971501234567'), 'Rolls-Royce', 'Ghost', 'DXB-B67890', 2023);

-- Inserting these fires trg_award_loyalty_points, which earns 1 point per
-- AED 10 of cost (floored) and upserts loyalty_accounts for the customer.
-- Expected total for Ahmed: 25 + 120 + 340 + 18 + 9 = 512 points.
insert into service_records (vehicle_id, customer_id, service_type, description, cost, source) values
  ((select id from vehicles where plate = 'DXB-A12345'), (select id from customers where phone = '+971501234567'), 'Oil Change', 'Full synthetic oil change', 250.00, 'manual'),
  ((select id from vehicles where plate = 'DXB-A12345'), (select id from customers where phone = '+971501234567'), 'Full Detailing', 'Interior + exterior detailing', 1200.00, 'manual'),
  ((select id from vehicles where plate = 'DXB-B67890'), (select id from customers where phone = '+971501234567'), 'Brake Replacement', 'Front and rear brake pads + rotors', 3400.50, 'manual'),
  ((select id from vehicles where plate = 'DXB-B67890'), (select id from customers where phone = '+971501234567'), 'Tire Rotation', 'Rotate and balance all 4 tires', 180.00, 'manual'),
  ((select id from vehicles where plate = 'DXB-A12345'), (select id from customers where phone = '+971501234567'), 'Annual Inspection', 'Full annual safety inspection', 95.00, 'manual');

insert into rewards (name, points_cost, description) values
  ('Free Oil Change', 200, 'Complimentary standard oil change service'),
  ('Premium Detailing Package', 1000, 'Full interior + exterior premium detailing');

-- Succeeds: Ahmed has 512 points, this costs 200 -> balance becomes 312.
insert into redemptions (customer_id, reward_id) values (
  (select id from customers where phone = '+971501234567'),
  (select id from rewards where name = 'Free Oil Change')
);

-- Expected to fail: Ahmed now has 312 points, this reward costs 1000.
-- trg_process_redemption raises "Insufficient points balance: has 312, needs 1000"
-- and the insert is rejected, leaving the redemptions/loyalty tables unchanged.
-- insert into redemptions (customer_id, reward_id) values (
--   (select id from customers where phone = '+971501234567'),
--   (select id from rewards where name = 'Premium Detailing Package')
-- );
