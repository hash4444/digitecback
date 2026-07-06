-- private.generate_loyalty_code() (a plain, non-SECURITY-DEFINER plpgsql
-- trigger function) calls private.new_loyalty_code() by qualified name.
-- That nested call runs as the invoking role (whoever's INSERT fired the
-- trigger), which needs USAGE on the `private` schema to resolve it --
-- schemas don't grant USAGE to PUBLIC by default the way `public` does.
-- Without this, a staff member's "create customer" insert fails with
-- "permission denied for schema private".

grant usage on schema private to authenticated;
