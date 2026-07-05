-- DIGI-TEC loyalty backend: point-calculation triggers
--
-- Both functions are SECURITY DEFINER so they can write to loyalty_accounts /
-- loyalty_transactions on behalf of whichever role performed the triggering
-- insert (entry staff, manager, or service-role import), even though no
-- direct RLS policy grants entry staff write access to those two tables.

create or replace function public.award_loyalty_points()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_points int;
begin
  v_points := floor(new.cost / 10)::int;

  insert into loyalty_transactions (customer_id, points, type, related_service_id, note)
  values (new.customer_id, v_points, 'earn', new.id, 'Earned from service: ' || new.service_type);

  insert into loyalty_accounts (customer_id, points_balance, updated_at)
  values (new.customer_id, v_points, now())
  on conflict (customer_id) do update
    set points_balance = loyalty_accounts.points_balance + excluded.points_balance,
        updated_at = now();

  return new;
end;
$$;

create trigger trg_award_loyalty_points
  after insert on service_records
  for each row execute function public.award_loyalty_points();

create or replace function public.process_redemption()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance int;
  v_cost int;
begin
  select points_cost into v_cost from rewards where id = new.reward_id;
  if v_cost is null then
    raise exception 'Reward % not found', new.reward_id;
  end if;

  -- Lock the account row for the duration of the transaction to avoid a race
  -- between concurrent redemptions overdrawing the balance.
  select points_balance into v_balance
  from loyalty_accounts
  where customer_id = new.customer_id
  for update;

  if v_balance is null then
    v_balance := 0;
  end if;

  if v_balance < v_cost then
    raise exception 'Insufficient points balance: has %, needs %', v_balance, v_cost;
  end if;

  insert into loyalty_accounts (customer_id, points_balance, updated_at)
  values (new.customer_id, -v_cost, now())
  on conflict (customer_id) do update
    set points_balance = loyalty_accounts.points_balance - v_cost,
        updated_at = now();

  insert into loyalty_transactions (customer_id, points, type, note)
  values (new.customer_id, -v_cost, 'redeem', 'Redeemed reward ' || new.reward_id);

  return new;
end;
$$;

create trigger trg_process_redemption
  before insert on redemptions
  for each row execute function public.process_redemption();
