-- Isolated integration tests for the deposit submission queue.
-- Submission is not verification and must never credit a wallet.
-- Runs only in the disposable PostgreSQL CI database.

begin;

create schema auth;
create table auth.users(id uuid primary key);
create or replace function auth.role()
returns text language sql stable
as $$ select current_setting('request.jwt.claim.role', true) $$;
create or replace function auth.uid()
returns uuid language sql stable
as $$ select nullif(current_setting('request.jwt.claim.sub', true),'')::uuid $$;

create table public.wallets (
  id uuid primary key,
  user_id uuid not null,
  asset_code text not null,
  balance numeric(30,10) not null
);

insert into auth.users(id) values
 ('10000000-0000-0000-0000-000000000301'),
 ('10000000-0000-0000-0000-000000000302');

insert into public.wallets(id,user_id,asset_code,balance) values
 ('00000000-0000-0000-0000-000000000301','10000000-0000-0000-0000-000000000301','USDT',42);

\i v2/supabase/migrations/008_deposit_submission_queue.sql

select set_config('request.jwt.claim.role','service_role',true);

do $$
declare
  v_id uuid;
  v_count integer;
  v_balance numeric;
  v_hash text := repeat('b',64);
begin
  v_id := public.nx_submit_deposit(
    '10000000-0000-0000-0000-000000000301',
    12.5,'TRON-TRC20',v_hash
  );
  if v_id is null then raise exception 'FAIL: valid deposit submission returned no ID'; end if;

  select count(*) into v_count from public.nx_deposit_submissions
    where id=v_id and user_id='10000000-0000-0000-0000-000000000301'
      and amount=12.5 and status='submitted' and tx_hash=v_hash;
  if v_count <> 1 then raise exception 'FAIL: submission record fields incorrect'; end if;

  -- Duplicate hashes cannot create a second submission.
  begin
    perform public.nx_submit_deposit(
      '10000000-0000-0000-0000-000000000302',
      12.5,'TRON-TRC20',v_hash
    );
    raise exception 'FAIL: duplicate transaction hash was accepted';
  exception when others then
    if sqlerrm <> 'transaction hash already submitted' then raise; end if;
  end;

  -- Invalid amount, network and hash must fail closed.
  begin
    perform public.nx_submit_deposit(
      '10000000-0000-0000-0000-000000000301',
      0,'TRON-TRC20',repeat('c',64)
    );
    raise exception 'FAIL: zero deposit amount was accepted';
  exception when others then
    if sqlerrm <> 'invalid amount' then raise; end if;
  end;
  begin
    perform public.nx_submit_deposit(
      '10000000-0000-0000-0000-000000000301',
      1,'ETHEREUM',repeat('d',64)
    );
    raise exception 'FAIL: unsupported network was accepted';
  exception when others then
    if sqlerrm <> 'unsupported network' then raise; end if;
  end;
  begin
    perform public.nx_submit_deposit(
      '10000000-0000-0000-0000-000000000301',
      1,'TRON-TRC20','not-a-transaction-hash'
    );
    raise exception 'FAIL: malformed transaction hash was accepted';
  exception when others then
    if sqlerrm <> 'invalid transaction hash' then raise; end if;
  end;

  -- Submission must never alter wallet balances or create ledger credit.
  select balance into v_balance from public.wallets
    where user_id='10000000-0000-0000-0000-000000000301';
  if v_balance <> 42 then raise exception 'FAIL: deposit submission credited wallet'; end if;
  if to_regclass('public.nx_wallet_ledger') is not null then
    execute 'select count(*) from public.nx_wallet_ledger where reference_id = $1'
      into v_count using v_id;
    if v_count <> 0 then raise exception 'FAIL: deposit submission created ledger entry'; end if;
  end if;

  raise notice 'PASS: deposit submission validation, unique hash, and no-credit invariant';
end $$;

rollback;
