-- Adds a short, scannable loyalty_code per customer for the staff admin
-- app's scan-to-lookup flow. QR content convention: encode "DIGITEC:{code}"
-- (not a bare code, not a deep link) -- see BACKEND.md.

alter table customers
  add column loyalty_code text unique;

-- Shared generator, used both by the insert trigger below and the one-time
-- backfill UPDATE, so the two don't drift out of sync with duplicated logic.
create or replace function private.new_loyalty_code()
returns text
language plpgsql
as $$
declare
  new_code text;
  attempts int := 0;
begin
  loop
    new_code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    exit when not exists (select 1 from customers where loyalty_code = new_code);
    attempts := attempts + 1;
    if attempts > 10 then
      raise exception 'Could not generate a unique loyalty code after 10 attempts';
    end if;
  end loop;
  return new_code;
end;
$$;

create or replace function private.generate_loyalty_code()
returns trigger
language plpgsql
as $$
begin
  new.loyalty_code := private.new_loyalty_code();
  return new;
end;
$$;

create trigger set_loyalty_code
before insert on customers
for each row
when (new.loyalty_code is null)
execute function private.generate_loyalty_code();

-- Backfill customers inserted before this column existed. The volatile
-- random()/clock_timestamp() calls inside new_loyalty_code() are
-- re-evaluated per row, so each customer gets a distinct code.
update customers set loyalty_code = private.new_loyalty_code() where loyalty_code is null;
