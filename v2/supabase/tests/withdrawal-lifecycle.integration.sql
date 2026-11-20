-- Isolated integration tests for withdrawal reserve, review, refund, and completion.
-- Runs only in the disposable PostgreSQL CI database. No Supabase or live funds.

begin;

create schema auth;
create or replace function auth.role()
returns text
language sql
stable
as $$ select current_setting('request.jwt.claim.role', true) $$;

create table public.wallets (
  id uuid primary key,
  user_id uuid not null,
  asset_code text not null,
  balance numeric(30,10) not null,
  updated_at timestamptz not null default now()
);

create table public.nx_wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  wallet_id uuid not null,
  user_id uuid not null,
  asset_code text not null,
  amount numeric(30,10) not null,
  entry_type text not null,
  reference_type text,
  reference_id uuid,
  idempotency_key text not null unique,
  metadata jsonb not null default '{}'::jsonb
);

create table public.nx_withdrawals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null,
  asset_code text not null default 'USDT',
  network_code text not null default 'TRON-TRC20',
  destination_address text not null,
  amount numeric(30,10) not null,
  fee_amount numeric(30,10) not null default 0,
  status text not null default 'requested',
  ledger_debit_id uuid,
  ledger_refund_id uuid,
  tx_hash text,
  rejection_reason text,
  reviewed_by uuid,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.nx_admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid,
  action text not null,
  target_type text,
  target_id text,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

insert into public.wallets(id,user_id,asset_code,balance) values
  ('00000000-0000-0000-0000-000000000201','10000000-0000-0000-0000-000000000201','USDT',100);

\i v2/supabase/migrations/011_ledger_retry_before_balance_check.sql
\i v2/supabase/migrations/005_atomic_withdrawal_request.sql
\i v2/supabase/migrations/010_withdrawal_idempotency_concurrency.sql
\i v2/supabase/migrations/006_admin_withdrawal_review.sql

select set_config('request.jwt.claim.role','service_role',true);

do $$
declare
  v_id uuid;
  v_again uuid;
  v_w public.nx_withdrawals%rowtype;
  v_balance numeric;
  v_count integer;
  v_hash text := repeat('a',64);
  v_address text := 'T123456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  v_admin uuid := '90000000-0000-0000-0000-000000000001';
  v_user uuid := '10000000-0000-0000-0000-000000000201';
begin
  -- A repeated request with the same key and details returns one withdrawal and reserves once.
  v_id := public.nx_request_withdrawal(v_user,20,1,'TRON-TRC20',v_address,'withdraw-test-0001');
  v_again := public.nx_request_withdrawal(v_user,20,1,'TRON-TRC20',v_address,'withdraw-test-0001');
  if v_id <> v_again then raise exception 'FAIL: withdrawal retry returned a different ID'; end if;
  select balance into v_balance from public.wallets where user_id=v_user;
  if v_balance <> 79 then raise exception 'FAIL: reserve should reduce balance to 79, got %',v_balance; end if;
  select count(*) into v_count from public.nx_withdrawals where user_id=v_user;
  if v_count <> 1 then raise exception 'FAIL: duplicate idempotency request created multiple withdrawals'; end if;
  select count(*) into v_count from public.nx_wallet_ledger where reference_id=v_id and entry_type='withdrawal_debit';
  if v_count <> 1 then raise exception 'FAIL: reserve ledger entry was duplicated or missing'; end if;

  -- Reusing a key for changed details is rejected.
  begin
    perform public.nx_request_withdrawal(v_user,21,1,'TRON-TRC20',v_address,'withdraw-test-0001');
    raise exception 'FAIL: changed withdrawal details were accepted for an existing key';
  exception when others then
    if sqlerrm <> 'idempotency key reused with different withdrawal details' then raise; end if;
  end;

  -- Rejection refunds amount plus fee exactly once and writes an audit record.
  v_w := public.nx_admin_review_withdrawal(v_id,v_admin,'reject','Test rejection');
  if v_w.status <> 'rejected' or v_w.ledger_refund_id is null then
    raise exception 'FAIL: rejected withdrawal is missing its refund';
  end if;
  select balance into v_balance from public.wallets where user_id=v_user;
  if v_balance <> 100 then raise exception 'FAIL: rejection did not restore full reserve, got %',v_balance; end if;
  select count(*) into v_count from public.nx_wallet_ledger where reference_id=v_id;
  if v_count <> 2 then raise exception 'FAIL: expected one reserve and one refund ledger entry'; end if;
  v_w := public.nx_admin_review_withdrawal(v_id,v_admin,'reject','Test rejection retry');
  if v_w.ledger_refund_id is null then raise exception 'FAIL: rejection retry lost refund reference'; end if;
  select count(*) into v_count from public.nx_wallet_ledger where reference_id=v_id;
  if v_count <> 2 then raise exception 'FAIL: rejection retry duplicated refund'; end if;

  -- Approval moves the withdrawal to processing; recording a verified-format hash completes it.
  v_id := public.nx_request_withdrawal(v_user,10,1,'TRON-TRC20',v_address,'withdraw-test-0002');
  v_w := public.nx_admin_review_withdrawal(v_id,v_admin,'approve',null);
  if v_w.status <> 'processing' then raise exception 'FAIL: approval did not move withdrawal to processing'; end if;
  v_w := public.nx_admin_complete_withdrawal(v_id,v_admin,v_hash);
  if v_w.status <> 'completed' or lower(v_w.tx_hash) <> v_hash then
    raise exception 'FAIL: withdrawal completion did not persist transaction hash';
  end if;
  v_w := public.nx_admin_complete_withdrawal(v_id,v_admin,v_hash);
  if v_w.status <> 'completed' then raise exception 'FAIL: completion retry was not idempotent'; end if;

  -- A transaction hash already used by another withdrawal cannot complete a second payout.
  v_id := public.nx_request_withdrawal(v_user,5,1,'TRON-TRC20',v_address,'withdraw-test-0003');
  v_w := public.nx_admin_review_withdrawal(v_id,v_admin,'approve',null);
  begin
    perform public.nx_admin_complete_withdrawal(v_id,v_admin,v_hash);
    raise exception 'FAIL: duplicate payout transaction hash was accepted';
  exception when others then
    if sqlerrm <> 'transaction hash already used' then raise; end if;
  end;

  raise notice 'PASS: withdrawal reserve, idempotency, changed details, rejection refund, approval, completion, and duplicate-hash checks';
end $$;

rollback;
