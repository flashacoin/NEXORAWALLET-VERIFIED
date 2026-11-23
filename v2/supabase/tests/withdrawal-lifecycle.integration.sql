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
\i v2/supabase/migrations/015_withdrawal_chain_verification.sql

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

  -- Approval moves the withdrawal to processing; a hash alone must not complete it.
  v_id := public.nx_request_withdrawal(v_user,10,1,'TRON-TRC20',v_address,'withdraw-test-0002');
  v_w := public.nx_admin_review_withdrawal(v_id,v_admin,'approve',null);
  if v_w.status <> 'processing' then raise exception 'FAIL: approval did not move withdrawal to processing'; end if;
  begin
    perform public.nx_admin_complete_withdrawal(v_id,v_admin,v_hash);
    raise exception 'FAIL: hash without verified evidence completed withdrawal';
  exception when others then
    if sqlerrm <> 'verified on-chain withdrawal evidence required' then raise; end if;
  end;
  -- Evidence must match the requested recipient, exact payout, and successful receipt.
  begin
    perform public.nx_record_withdrawal_evidence(
      v_id,v_hash,0,'TUSDTContractAddress','TSenderAddress','TWrongRecipientAddress','10000000',123456,20,'SUCCESS','test-verifier'
    );
    raise exception 'FAIL: wrong withdrawal recipient evidence was accepted';
  exception when others then
    if sqlerrm <> 'withdrawal recipient mismatch' then raise; end if;
  end;
  begin
    perform public.nx_record_withdrawal_evidence(
      v_id,v_hash,0,'TUSDTContractAddress','TSenderAddress',v_address,'9000000',123456,20,'SUCCESS','test-verifier'
    );
    raise exception 'FAIL: short withdrawal payout evidence was accepted';
  exception when others then
    if sqlerrm <> 'withdrawal payout amount mismatch' then raise; end if;
  end;
  begin
    perform public.nx_record_withdrawal_evidence(
      v_id,v_hash,0,'TUSDTContractAddress','TSenderAddress',v_address,'10000000',123456,20,'FAILED','test-verifier'
    );
    raise exception 'FAIL: failed receipt evidence was accepted';
  exception when others then
    if sqlerrm <> 'invalid withdrawal evidence' then raise; end if;
  end;
  begin
    perform public.nx_record_withdrawal_evidence(
      v_id,v_hash,0,'TUSDTContractAddress','TSenderAddress',v_address,'10000000',123456,0,'SUCCESS','test-verifier'
    );
    raise exception 'FAIL: zero-confirmation evidence was accepted';
  exception when others then
    if sqlerrm <> 'invalid withdrawal evidence' then raise; end if;
  end;

  -- A verified transfer must pay the full requested amount (10 USDT); the 1 USDT fee is on top.
  perform public.nx_record_withdrawal_evidence(
    v_id,v_hash,0,'TUSDTContractAddress','TSenderAddress',v_address,'10000000',123456,20,'SUCCESS','test-verifier'
  );
  v_w := public.nx_admin_complete_withdrawal(v_id,v_admin,v_hash);
  if v_w.status <> 'completed' or lower(v_w.tx_hash) <> v_hash then
    raise exception 'FAIL: evidence-backed withdrawal completion did not persist transaction hash';
  end if;
  v_w := public.nx_admin_complete_withdrawal(v_id,v_admin,v_hash);
  if v_w.status <> 'completed' then raise exception 'FAIL: evidence-backed completion retry was not idempotent'; end if;

  -- A transaction hash already used by another withdrawal cannot complete a second payout.
  v_id := public.nx_request_withdrawal(v_user,5,1,'TRON-TRC20',v_address,'withdraw-test-0003');
  v_w := public.nx_admin_review_withdrawal(v_id,v_admin,'approve',null);
  -- A second distinct event from the same transaction hash cannot be reused for another withdrawal.
  perform public.nx_record_withdrawal_evidence(
    v_id,v_hash,1,'TUSDTContractAddress','TSenderAddress',v_address,'5000000',123456,20,'SUCCESS','test-verifier'
  );
  begin
    perform public.nx_admin_complete_withdrawal(v_id,v_admin,v_hash);
    raise exception 'FAIL: duplicate payout transaction hash was accepted';
  exception when others then
    if sqlerrm <> 'transaction hash already used' then raise; end if;
  end;

  -- Amounts that cannot be represented by six-decimal TRC20 USDT are rejected.
  begin
    perform public.nx_request_withdrawal(v_user,1.0000001,0,'TRON-TRC20',v_address,'withdraw-test-precision');
    raise exception 'FAIL: seven-decimal withdrawal amount was accepted';
  exception when others then
    if sqlerrm <> 'withdrawal amount must use at most six decimal places' then raise; end if;
  end;

  raise notice 'PASS: withdrawal reserve, idempotency, changed details, rejection refund, approval, evidence-required completion, exact full payout, duplicate-hash, and six-decimal precision checks';
end $$;

rollback;
