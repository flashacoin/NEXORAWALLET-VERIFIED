-- NEXORA V2: prevent a payout transaction hash from being attached to multiple withdrawals.
-- Apply in staging first. This migration intentionally fails if legacy duplicates exist,
-- requiring manual review rather than silently choosing a record.
create unique index if not exists nx_withdrawals_tx_hash_unique
  on public.nx_withdrawals (lower(tx_hash))
  where tx_hash is not null and length(trim(tx_hash)) > 0;
