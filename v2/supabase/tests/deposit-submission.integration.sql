-- Isolated integration tests for deposit submission and immutable evidence.
-- Evidence recording is not settlement and must never credit a wallet.
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
\i v2/supabase/migrations/013_deposit_verification_evidence.sql

select set_config('request.jwt.claim.role','service_role',true);

do $$
declare
  v_id uuid;
  v_evidence jsonb;
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

  v_evidence := public.nx_record_deposit_evidence(
    v_hash, 3, 'TOfficialUSDT', 'TSender', 'TConfiguredDeposit',
    '12500000', 100, 20, 'SUCCESS', 'tron-solidified-v1'
  );
  if v_evidence->>'matched' <> 'true' or v_evidence->>'duplicate_retry' <> 'false' then
    raise exception 'FAIL: exact evidence did not match';
  end if;

  if public.nx_record_deposit_evidence(
    v_hash, 3, 'TOfficialUSDT', 'TSender', 'TConfiguredDeposit',
    '12500000', 100, 25, 'SUCCESS', 'tron-solidified-v1'
  )->>'evidence_id' <> v_evidence->>'evidence_id' then
    raise exception 'FAIL: evidence retry did not return original ID';
  end if;

  if public.nx_record_deposit_evidence(
    v_hash, 3, 'TOfficialUSDT', 'TSender', 'TConfiguredDeposit',
    '12500001', 100, 20, 'SUCCESS', 'tron-solidified-v1'
  )->>'matched' <> 'false' then
    raise exception 'FAIL: mismatched amount was accepted';
  end if;

  if public.nx_record_deposit_evidence(
    v_hash, 4, 'TOfficialUSDT', 'TSender', 'TConfiguredDeposit',
    '12500000', 100, 20, 'SUCCESS', 'tron-solidified-v1'
  )->>'reason' <> 'duplicate_event_or_submission' then
    raise exception 'FAIL: second event was attached to one submission';
  end if;

  if public.nx_record_deposit_evidence(
    repeat('c',64), 0, 'TOfficialUSDT', 'TSender', 'TConfiguredDeposit',
    '12500000', 100, 20, 'SUCCESS', 'tron-solidified-v1'
  )->>'reason' <> 'no_matching_submission' then
    raise exception 'FAIL: unmatched transaction was persisted';
  end if;

  select count(*) into v_count from public.nx_deposit_verification_evidence
    where submission_id=v_id;
  if v_count <> 1 then raise exception 'FAIL: evidence uniqueness failed'; end if;

  if has_table_privilege('authenticated','public.nx_deposit_verification_evidence','select') then
    raise exception 'FAIL: authenticated role can read evidence table directly';
  end if;
  if has_table_privilege('service_role','public.nx_deposit_verification_evidence','insert') then
    raise exception 'FAIL: service role can bypass evidence RPC';
  end if;

  begin
    update public.nx_deposit_verification_evidence
      set confirmations=confirmations+1 where submission_id=v_id;
    raise exception 'FAIL: evidence update was accepted';
  exception when others then
    if sqlerrm <> 'deposit verification evidence is immutable' then raise; end if;
  end;
  begin
    delete from public.nx_deposit_verification_evidence where submission_id=v_id;
    raise exception 'FAIL: evidence delete was accepted';
  exception when others then
    if sqlerrm <> 'deposit verification evidence is immutable' then raise; end if;
  end;

  begin
    perform public.nx_submit_deposit(
      '10000000-0000-0000-0000-000000000302',
      12.5,'TRON-TRC20',v_hash
    );
    raise exception 'FAIL: duplicate transaction hash was accepted';
  exception when others then
    if sqlerrm <> 'transaction hash already submitted' then raise; end if;
  end;

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

  select balance into v_balance from public.wallets
    where user_id='10000000-0000-0000-0000-000000000301';
  if v_balance <> 42 then raise exception 'FAIL: evidence recording credited wallet'; end if;
  if (select status from public.nx_deposit_submissions where id=v_id) <> 'submitted' then
    raise exception 'FAIL: evidence recording changed submission status';
  end if;
  if to_regclass('public.nx_wallet_ledger') is not null then
    execute 'select count(*) from public.nx_wallet_ledger where reference_id = $1'
      into v_count using v_id;
    if v_count <> 0 then raise exception 'FAIL: evidence recording created ledger entry'; end if;
  end if;

  raise notice 'PASS: exact deposit evidence matching, immutable storage, idempotent retry, and no-credit invariants';
end $$;

rollback;
