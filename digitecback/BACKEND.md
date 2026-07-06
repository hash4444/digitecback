# DIGI-TEC Loyalty Backend

Supabase backend for the DIGI-TEC customer loyalty/retention app. Built standalone
(no frontend yet) to support a future staff admin web app and a customer mobile app.

## Project

| | |
|---|---|
| Project name | `digitec-loyalty` |
| Project ref | `zerylxncpucnxqprojpv` |
| Region | `eu-central-1` |
| API URL | `https://zerylxncpucnxqprojpv.supabase.co` |
| Anon (legacy) key | `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InplcnlseG5jcHVjbnhxcHJvanB2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMyODY3NDcsImV4cCI6MjA5ODg2Mjc0N30.X48HDX9X9f-okEMNRXGDoHfFtUeryavpIotfWz8Qnyo` |
| Publishable key | `sb_publishable_jeevsBLmck7fxkDaYVugEQ_dolWupQf` |
| Service role key | Not included here — pull it from the Supabase dashboard (Project Settings → API) when wiring up the staff admin app / Edge Functions. It must stay server-side only. |

Client apps (mobile + admin) should use the **publishable key** (or legacy anon key)
plus a user's Supabase Auth session. Only trusted server-side code (Edge Functions,
admin scripts) should ever use the service role key.

## Schema

All tables live in `public`, RLS enabled on every one. See `supabase/migrations/`
for the exact SQL (applied in order, mirrors what's live in the project).

- **staff_users** — `id, name, role (entry|manager), auth_user_id -> auth.users, created_at`
- **customers** — `id, name, phone (unique), email, created_at`
- **vehicles** — `id, customer_id -> customers, make, model, plate, year, created_at`
- **service_records** — `id, vehicle_id -> vehicles, customer_id -> customers, service_type, description, cost, date, entered_by -> staff_users, source (manual|csv_import|api), created_at`
- **loyalty_accounts** — `customer_id (PK) -> customers, points_balance, tier, updated_at`
- **loyalty_transactions** — `id, customer_id -> customers, points, type (earn|redeem|adjustment), related_service_id -> service_records, note, date`
- **rewards** — `id, name, points_cost, description, active, created_at`
- **redemptions** — `id, customer_id -> customers, reward_id -> rewards, date, status (pending|fulfilled|cancelled)`
- **service_bookings** — `id, customer_id -> customers, vehicle_id -> vehicles, service_type, address, requested_time, status (requested|confirmed|in_progress|completed|cancelled), technician_id -> staff_users, notes, created_at`

Indexes: `customer_id` on vehicles/service_records/loyalty_transactions/redemptions,
`vehicle_id` on service_records, `phone` on customers (also unique), plus covering
indexes on `service_records.entered_by` and `loyalty_transactions.related_service_id`
(added after the performance advisor flagged them as unindexed foreign keys).

## Auth model

- **Customers** sign in via Supabase Auth phone OTP. Their verified phone number
  arrives in the JWT as the `phone` claim and is matched against `customers.phone`
  (must be stored in the same E.164 format Supabase Auth uses).
- **Staff** sign in via Supabase Auth (email/password or similar) and are linked to
  a `staff_users` row via `staff_users.auth_user_id = auth.uid()`.
- Two `SECURITY DEFINER` helper functions, `private.current_customer_id()` and
  `private.current_staff_role()`, do these lookups once and are referenced from
  every policy. They live in a `private` schema (not exposed via PostgREST) rather
  than `public`, so they're usable inside RLS policies but not callable directly
  as a public API endpoint — this was a fix for a security-advisor warning (see
  below).

## RLS policies (see `supabase/migrations/*_rls.sql` and `*_optimize_rls_performance.sql`)

- **customers / vehicles / service_records / loyalty_accounts / loyalty_transactions / redemptions**: a customer can `SELECT` only rows where `customer_id` (or their own `customers` row) matches their JWT phone. No customer `INSERT`/`UPDATE`/`DELETE` on any of these — matches the spec.
- **staff (`entry`)**: can `INSERT` into `customers`, `vehicles`, `service_records`.
- **staff (`manager`)**: full read/write on `rewards`; can `INSERT` `loyalty_transactions` rows with `type='adjustment'`; can `UPDATE` `redemptions.status`.
- All staff (`entry` or `manager`) can `SELECT` across all operational tables — needed for the admin app to look up existing customers/vehicles/history during manual entry (the spec didn't say otherwise, and it's required for the stated "manual service entry" workflow).

## Loyalty triggers (see `supabase/migrations/*_loyalty_triggers.sql`)

- `award_loyalty_points()` — `AFTER INSERT` on `service_records`. Awards `floor(cost / 10)` points, inserts a `loyalty_transactions` row (`type='earn'`), and upserts `loyalty_accounts.points_balance`.
- `process_redemption()` — `BEFORE INSERT` on `redemptions`. Locks the customer's `loyalty_accounts` row (`FOR UPDATE`, avoiding a race on concurrent redemptions), checks the reward's `points_cost` against the balance, and either deducts the balance + logs a `loyalty_transactions` row (`type='redeem'`, negative points) or raises an exception that aborts the insert.
- Both functions are `SECURITY DEFINER` (so they can write to `loyalty_accounts`/`loyalty_transactions` regardless of the calling role's own grants) but have direct `EXECUTE` revoked from `anon`/`authenticated` — they should only ever run via the trigger engine, not be called directly as an RPC.

## Manager point-adjustment RPC (see `supabase/migrations/20260706000001_manager_point_adjustment_rpc.sql`)

Fixes a gap flagged above: managers previously could only insert an audit row into
`loyalty_transactions` (`type='adjustment'`) with no path that actually moved
`loyalty_accounts.points_balance`. `public.adjust_loyalty_points(p_customer_id, p_points, p_note)`:

1. Rejects the call outright unless the caller is a `manager` (checked *inside* the
   function body with `private.current_staff_role() is distinct from 'manager'` —
   `SECURITY DEFINER` execution bypasses table RLS entirely, so RLS can't be the
   thing gating who may call this; the `is distinct from` form also correctly
   rejects a non-staff caller, for whom `current_staff_role()` returns `NULL`,
   rather than letting `<> 'manager'` silently evaluate to `NULL`/false).
2. Inserts the `loyalty_transactions` audit row (`type='adjustment'`).
3. Upserts `loyalty_accounts.points_balance += p_points` (upsert, not a bare
   `update`, so it still works for a customer with no prior `loyalty_accounts` row).
4. Raises an exception — rolling back both writes — if the resulting balance would
   go negative.

**Deviation:** the request asked for this to live in the `private` schema, matching
`current_customer_id`/`current_staff_role`. That's not possible while also exposing
it as an RPC: `private` is deliberately excluded from PostgREST's exposed-schema
list (that's *why* those two helpers live there — to keep them off the public RPC
surface). A function meant to be called via `supabase.rpc()` must live in an
exposed schema, so `adjust_loyalty_points` is `public.*` instead, with `EXECUTE`
revoked from `anon` and granted only to `authenticated`, and the manager check
enforced on every call. `get_advisors` does flag this function as "callable by
`authenticated`" — that WARN is expected and unavoidable for a function that must
be RPC-callable; eliminating it would mean revoking `authenticated`'s execute too,
which defeats the point.

**Tested live** using the project's existing `Test Manager` / `Test Entry Staff`
accounts (already provisioned in `staff_users`/`auth.users` — not created by this
change), by simulating each one's session in the SQL console
(`set local role authenticated; select set_config('request.jwt.claims', ...)`):
- Manager call with `+50` points on Ahmed Al Maktoum's account: succeeded, balance
  moved 322 → 372, audit row recorded.
- Manager call with `-500` points (would go negative): rejected with
  `Adjustment would result in negative balance`; balance confirmed unchanged at 372.
- Entry-staff call: rejected with `Only managers may adjust loyalty points`.

**Not done:** updating the staff admin app's point-adjustment call site to use
`supabase.rpc('adjust_loyalty_points', ...)` instead of a raw insert — there's no
staff admin app in this repo/session to change. Apply that one-line swap wherever
that app's code lives.

**Left untouched (out of scope for this change):** the existing
`loyalty_transactions_insert_manager_adjustment` policy still lets a manager
insert an audit-only row directly (the original bug path). Worth revoking once the
staff admin app is switched over to the RPC, so it becomes the only route — flagging
it rather than removing it now, since the instruction was not to touch anything else.

## New table: `service_bookings` (see `supabase/migrations/20260706000002_service_bookings.sql`)

At-home service booking queue (Phase 3, moved up):
`id, customer_id -> customers, vehicle_id -> vehicles, service_type, address, requested_time, status (requested|confirmed|in_progress|completed|cancelled), technician_id -> staff_users, notes, created_at`.
Indexed on `customer_id`, `vehicle_id`, `technician_id`. RLS enabled, no trigger (no
loyalty-point interaction yet — **flagging back**: does an at-home booking earn
points the same way an in-shop `service_records` row does? That changes the trigger
logic and wasn't specified, so nothing fires today.)

- **Customer**: can `INSERT` a booking with their own `customer_id`, can `SELECT`
  only their own bookings. No `UPDATE` policy for the customer role at all
  (default-deny), so they cannot change status once submitted.
- **Staff (`entry` or `manager`)**: can `SELECT` all bookings; can `UPDATE` rows,
  but *only* the `status` and `technician_id` columns — enforced with a real
  Postgres column-level privilege (`revoke update ... from authenticated; grant
  update (status, technician_id) ... to authenticated`), not just policy wording.
  RLS still governs which *rows* they can touch (must be staff); the column grant
  governs which *columns* can appear in the `SET` clause at all, for anyone.

**Tested live**, again by simulating sessions in the SQL console:
- Inserted a booking as customer Ahmed (matched via JWT `phone` claim): succeeded,
  and the customer's own `SELECT` showed the row back.
- Same customer attempting `update ... set status = 'cancelled'`: RLS silently
  matched zero rows — status stayed `requested` (no error; this is normal Postgres
  RLS behavior for an `UPDATE` with no matching policy row, not a thrown exception).
- Entry-staff session: `update ... set status = 'confirmed', technician_id = ...`
  succeeded.
- Entry-staff session attempting to also change `address` in the same statement:
  rejected outright with `permission denied for table service_bookings` — confirms
  the column-level lock actually restricts staff to `status`/`technician_id` only,
  not just documentation.

Test artifacts left in place from this validation (not cleaned up, since the ask
was to run and confirm these tests): Ahmed Al Maktoum's `loyalty_accounts` balance
now includes the `+50` test adjustment (372, up from the 312 in the original seed
validation), and one `service_bookings` row exists for his Bentley.

## Schema drift found (not introduced by this change, not modified)

While re-verifying state before these two additions, the live database already
contained objects with no corresponding migration in this repo:
- `private.normalized_phone(text)` — strips non-digits from a phone string.
- `vehicles_insert_customer` policy on `vehicles` — lets a customer insert their
  own vehicle directly (`customer_id = private.current_customer_id()`).
- `redemptions_insert_customer_pending` policy on `redemptions` — lets a customer
  self-insert a `pending` redemption for an active reward directly.

These weren't created by this session and, per the instruction not to touch
anything else, weren't modified or backfilled into `supabase/migrations/`. Flagging
so the repo's migrations are known to no longer be a complete description of the
live schema — worth reconciling (either write a migration capturing these, or
confirm they were intentional dashboard/SQL-console changes) before anyone runs
`supabase db reset` against a fresh project expecting parity. `get_advisors` also
already reports pre-existing WARNs tied to this drift (`normalized_phone`'s mutable
search_path, and duplicate permissive INSERT policies on `vehicles`/`redemptions`
now that both a customer and a staff insert policy exist on each) plus one
project-level item (`auth_leaked_password_protection` disabled) — none of these
are from this session's changes.

## Deviations from the spec, and why

1. **Auth-to-row matching implementation.** The spec said "matched on phone" but didn't specify the mechanism. Implemented via the Supabase Auth JWT `phone` claim rather than adding an extra `auth_user_id` column to `customers`, since it requires no additional signup-linking step — this does assume `customers.phone` is stored in the same E.164 format used by Supabase phone auth.
2. **Redemptions insert access.** The spec disallows customer writes on every one of these six tables (including `redemptions`), but doesn't say who else can insert one. Since customers can't self-serve a redemption, staff (`entry` or `manager`) insert `redemptions` on the customer's behalf (e.g., at checkout). A future Edge Function using the service role key could add customer self-service redemption requests without changing this table's direct-write policy.
3. **Rewards catalog readable by customers.** Not covered by the spec's read-access list, but the loyalty mobile app needs to show customers what they can redeem — added a policy letting any matched customer `SELECT` active rewards.
4. **No update/delete policies on `customers`/`vehicles`.** The spec doesn't ask for them; left unpoliced (default-deny) rather than guessing at a workflow. Add explicit policies later once the admin app's edit flow is defined.
5. **Security/performance hardening beyond the spec's ask.** `get_advisors` initially flagged the RLS helper functions and trigger functions as publicly callable `SECURITY DEFINER` RPC endpoints, plus per-row re-evaluation of `auth.jwt()`/`auth.uid()` and duplicate permissive policies. Fixed by moving helpers to a `private` schema, revoking direct execute on trigger functions, wrapping `auth.*()` calls in scalar subselects, and merging the "own" + "staff" SELECT policies per table into one. Behavior is unchanged; `get_advisors` now reports zero security findings and zero WARN-level performance findings (only informational "unused index" notices remain, expected on a freshly seeded database).
6. **RLS was verified structurally, not via a live authenticated session.** Every table's policies were confirmed correct via `list_tables`/`get_advisors` and by reading the applied SQL, but the actual seed/redemption testing below was run through the SQL console (which bypasses RLS), not through a real Supabase Auth session. A true end-to-end "log in as this customer and confirm you only see your own rows" check needs a live client and is best done once the mobile/admin apps exist to drive it.

## Seed data & validation (see `supabase/seed.sql`)

Seeded and confirmed live in the project:
- 3 customers (one, Ahmed Al Maktoum, with 2 vehicles)
- 5 `service_records` across those 2 vehicles, costs ranging AED 95–3,400.50
- Confirmed `loyalty_accounts.points_balance` = **512** after all 5 inserts (25+120+340+18+9, i.e. `floor(cost/10)` per record) — trigger math verified correct
- 2 rewards (`Free Oil Change` @ 200 pts, `Premium Detailing Package` @ 1000 pts)
- 1 redemption that **succeeded** (200 pts, balance 512 → 312)
- 1 redemption that **correctly failed**: attempting the 1000-point reward against a 312-point balance raised `Insufficient points balance: has 312, needs 1000` and the insert was rejected — balance and transaction/redemption row counts confirmed unchanged afterward

## Files

- `supabase/migrations/` — schema, RLS, triggers, advisor-driven hardening/perf migrations, the manager point-adjustment RPC, and `service_bookings`, in application order
- `supabase/seed.sql` — the original seed test data, safe to re-run via `supabase db reset` on a fresh local project (does not include the `service_bookings`/RPC validation test artifacts noted above)
