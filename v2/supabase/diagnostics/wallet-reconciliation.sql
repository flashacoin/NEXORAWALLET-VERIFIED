-- NEXORA V2 staging-only reconciliation queries.
-- READ ONLY: run in Supabase SQL editor against a staging project.
-- These queries report discrepancies; they do not repair or alter records.

-- 1) Wallet balance vs ledger sum (should return no rows after opening-balance
--    backfill and after every financial write is ledger-posted).
select
  w.id as wallet_id,
  w.user_id,
  w.asset_code,
  w.balance as wallet_balance,
  coalesce(sum(l.amount), 0) as ledger_balance,
  w.balance - coalesce(sum(l.amount), 0) as difference
from public.wallets w
left join public.nx_wallet_ledger l
  on l.wallet_id = w.id
 and l.asset_code = w.asset_code
group by w.id, w.user_id, w.asset_code, w.balance
having w.balance <> coalesce(sum(l.amount), 0)
order by abs(w.balance - coalesce(sum(l.amount), 0)) desc;

-- 2) Deposits marked credited but missing a ledger reference.
select id, user_id, tx_hash, amount, status, ledger_id, credited_at
from public.nx_deposits
where status = 'credited'
  and (ledger_id is null or credited_at is null);

-- 3) Deposit ledger references that do not resolve.
select d.id as deposit_id, d.ledger_id
from public.nx_deposits d
left join public.nx_wallet_ledger l on l.id = d.ledger_id
where d.ledger_id is not null and l.id is null;

-- 4) Withdrawals with missing reserve ledger references.
select id, user_id, amount, fee_amount, status, ledger_debit_id
from public.nx_withdrawals
where status in ('requested','review','approved','processing','completed')
  and ledger_debit_id is null;

-- 5) Rejected withdrawals missing a refund reference.
select id, user_id, amount, fee_amount, status, ledger_refund_id, rejection_reason
from public.nx_withdrawals
where status = 'rejected' and ledger_refund_id is null;

-- 6) Completed withdrawals missing a payout transaction hash.
select id, user_id, status, tx_hash, updated_at
from public.nx_withdrawals
where status = 'completed'
  and (tx_hash is null or length(trim(tx_hash)) = 0);

-- 7) Duplicate payout hashes (unique index migration 009 should prevent these).
select lower(tx_hash) as normalized_hash, count(*) as row_count,
       array_agg(id order by created_at) as withdrawal_ids
from public.nx_withdrawals
where tx_hash is not null and length(trim(tx_hash)) > 0
group by lower(tx_hash)
having count(*) > 1;

-- 8) Ledger rows with a wallet/user/asset mismatch.
select l.id as ledger_id, l.wallet_id, l.user_id, l.asset_code,
       w.user_id as wallet_user_id, w.asset_code as wallet_asset_code
from public.nx_wallet_ledger l
left join public.wallets w on w.id = l.wallet_id
where w.id is null
   or w.user_id <> l.user_id
   or w.asset_code <> l.asset_code;
