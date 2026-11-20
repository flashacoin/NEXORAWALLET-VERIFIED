-- Isolated integration tests for wallet-funded order payment and cancellation.
-- Runs only in the disposable PostgreSQL CI database. No Supabase or live data.

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

create table public.nx_payment_orders (
  id uuid primary key,
  user_id uuid not null,
  product_code text not null,
  currency text not null,
  amount numeric(30,10) not null,
  status text not null,
  provider text not null,
  payment_method text,
  expires_at timestamptz,
  paid_at timestamptz,
  payment_verified_at timestamptz,
  fulfillment_key text,
  fulfillment_status text not null default 'not_started',
  updated_at timestamptz not null default now(),
  version integer not null default 1
);

create table public.nx_fulfillment_jobs (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null unique,
  fulfillment_key text not null unique,
  job_status text not null
);

insert into public.wallets(id,user_id,asset_code,balance) values
  ('00000000-0000-0000-0000-000000000101','10000000-0000-0000-0000-000000000101','USDT',100),
  ('00000000-0000-0000-0000-000000000102','10000000-0000-0000-0000-000000000102','USDT',50);

insert into public.nx_payment_orders(id,user_id,product_code,currency,amount,status,provider,payment_method)
values
  ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000101','TEST-25','USDT',25,'pending','wallet','wallet'),
  ('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000101','TEST-200','USDT',200,'pending','wallet','wallet'),
  ('20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000101','TEST-CANCEL','USDT',10,'pending','wallet','wallet');

insert into public.nx_payment_orders(id,user_id,product_code,currency,amount,status,provider,payment_method,expires_at)
values ('20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000101','TEST-EXPIRED','USDT',10,'pending','wallet','wallet',now()-interval '1 minute');

\i v2/supabase/migrations/011_ledger_retry_before_balance_check.sql
\i v2/supabase/migrations/003_atomic_wallet_order_payment.sql
\i v2/supabase/migrations/004_atomic_order_cancellation.sql

select set_config('request.jwt.claim.role','service_role',true);

do $$
declare
  v_result jsonb;
  v_balance numeric;
  v_count integer;
  v_status text;
begin
  -- A successful payment debits exactly once and creates one durable fulfillment job.
  v_result := public.nx_pay_order_with_wallet(
    '20000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000101'
  );
  if v_result->>'status' <> 'paid' or v_result->>'reused' <> 'false' then
    raise exception 'FAIL: first wallet payment did not settle';
  end if;
  select balance into v_balance from public.wallets
    where id='00000000-0000-0000-0000-000000000101';
  if v_balance <> 75 then raise exception 'FAIL: wallet balance after payment should be 75, got %',v_balance; end if;
  select count(*) into v_count from public.nx_wallet_ledger
    where idempotency_key='wallet-pay:20000000-0000-0000-0000-000000000001';
  if v_count <> 1 then raise exception 'FAIL: expected exactly one payment ledger entry'; end if;
  select count(*) into v_count from public.nx_fulfillment_jobs
    where order_id='20000000-0000-0000-0000-000000000001' and job_status='queued';
  if v_count <> 1 then raise exception 'FAIL: expected one queued fulfillment job'; end if;

  -- Repeating the paid order must not debit or enqueue a second job.
  v_result := public.nx_pay_order_with_wallet(
    '20000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000101'
  );
  if v_result->>'reused' <> 'true' then raise exception 'FAIL: paid-order retry was not idempotent'; end if;
  select balance into v_balance from public.wallets
    where id='00000000-0000-0000-0000-000000000101';
  select count(*) into v_count from public.nx_wallet_ledger
    where idempotency_key='wallet-pay:20000000-0000-0000-0000-000000000001';
  if v_balance <> 75 or v_count <> 1 then raise exception 'FAIL: retry changed balance or duplicated ledger'; end if;
  select count(*) into v_count from public.nx_fulfillment_jobs
    where order_id='20000000-0000-0000-0000-000000000001';
  if v_count <> 1 then raise exception 'FAIL: retry duplicated fulfillment job'; end if;

  -- Wrong owner must be rejected without changing the wallet.
  begin
    perform public.nx_pay_order_with_wallet(
      '20000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000102'
    );
    raise exception 'FAIL: mismatched order owner was accepted';
  exception when others then
    if sqlerrm <> 'order owner mismatch' then raise; end if;
  end;

  -- Insufficient funds must roll back the order, ledger, and fulfillment changes.
  begin
    perform public.nx_pay_order_with_wallet(
      '20000000-0000-0000-0000-000000000002',
      '10000000-0000-0000-0000-000000000101'
    );
    raise exception 'FAIL: insufficient-balance payment was accepted';
  exception when others then
    if sqlerrm <> 'insufficient balance' then raise; end if;
  end;
  select status into v_status from public.nx_payment_orders
    where id='20000000-0000-0000-0000-000000000002';
  if v_status <> 'pending' then raise exception 'FAIL: insufficient payment changed order status'; end if;
  select balance into v_balance from public.wallets
    where id='00000000-0000-0000-0000-000000000101';
  if v_balance <> 75 then raise exception 'FAIL: insufficient payment changed balance'; end if;
  select count(*) into v_count from public.nx_wallet_ledger
    where reference_id='20000000-0000-0000-0000-000000000002';
  if v_count <> 0 then raise exception 'FAIL: insufficient payment wrote ledger'; end if;

  -- Expired orders are marked expired without a debit.
  v_result := public.nx_pay_order_with_wallet(
    '20000000-0000-0000-0000-000000000003',
    '10000000-0000-0000-0000-000000000101'
  );
  if v_result->>'status' <> 'expired' then raise exception 'FAIL: expired order was not rejected'; end if;

  -- Cancellation is idempotent and a cancelled order cannot later be paid.
  v_result := public.nx_cancel_payment_order(
    '20000000-0000-0000-0000-000000000004',
    '10000000-0000-0000-0000-000000000101'
  );
  if v_result->>'status' <> 'cancelled' or v_result->>'reused' <> 'false' then
    raise exception 'FAIL: pending order cancellation failed';
  end if;
  v_result := public.nx_cancel_payment_order(
    '20000000-0000-0000-0000-000000000004',
    '10000000-0000-0000-0000-000000000101'
  );
  if v_result->>'reused' <> 'true' then raise exception 'FAIL: cancellation retry was not idempotent'; end if;
  begin
    perform public.nx_pay_order_with_wallet(
      '20000000-0000-0000-0000-000000000004',
      '10000000-0000-0000-0000-000000000101'
    );
    raise exception 'FAIL: cancelled order was paid';
  exception when others then
    if sqlerrm <> 'order is not pending' then raise; end if;
  end;

  raise notice 'PASS: wallet payment, retry, owner, insufficient funds, expiry, and cancellation integration checks';
end $$;

rollback;
