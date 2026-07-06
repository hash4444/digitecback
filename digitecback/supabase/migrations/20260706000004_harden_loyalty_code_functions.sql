-- Closes function_search_path_mutable advisor findings introduced by the
-- previous migration: private.new_loyalty_code / private.generate_loyalty_code
-- didn't set search_path explicitly, unlike every other function in this schema.

alter function private.new_loyalty_code() set search_path = public;
alter function private.generate_loyalty_code() set search_path = public;
