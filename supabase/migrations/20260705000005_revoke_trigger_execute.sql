-- Supabase grants EXECUTE directly to anon/authenticated in addition to
-- PUBLIC, so "revoke ... from public" alone did not fully clear the advisor
-- warning for the trigger functions. Revoke from all three explicitly.

revoke execute on function public.award_loyalty_points() from public, anon, authenticated;
revoke execute on function public.process_redemption() from public, anon, authenticated;
