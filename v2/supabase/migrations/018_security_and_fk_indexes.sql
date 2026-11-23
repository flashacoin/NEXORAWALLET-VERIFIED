-- Security and performance hardening identified by Supabase advisors.
-- The user-creation trigger remains functional; direct RPC execution is revoked.
revoke execute on function public.handle_new_wallet_user() from public, anon, authenticated;

-- Cover existing foreign keys flagged by the Supabase performance advisor.
create index if not exists deposit_requests_user_id_idx
  on public.deposit_requests(user_id);
create index if not exists notifications_user_id_idx
  on public.notifications(user_id);
create index if not exists transaction_ledger_user_id_idx
  on public.transaction_ledger(user_id);
create index if not exists transaction_ledger_wallet_id_idx
  on public.transaction_ledger(wallet_id);
create index if not exists withdrawal_requests_user_id_idx
  on public.withdrawal_requests(user_id);
