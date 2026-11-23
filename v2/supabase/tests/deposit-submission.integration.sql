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
  balance numeric(30,10) not null,
  updated_at timestamptz not null default now()
);

insert into auth.users(id) values
 ('10000000-0000-0000-0000-000000000301'),
 ('10000000-0000-0000-0000-000000000302');

insert into public.wallets(id,user_id,asset_code,balance) values
 ('00000000-0000-0000-0000-000000000301','10000000-0000-0000-0000-000000000301','USDT',42);

\i v2/supabase/migrations/001_wallet_ledger.sql
\i v2/supabase/migrations/008_deposit_submission_queue.sql
\i v2/supabase/migrations/013_deposit_verification_evidence.sql

-- Simulate a legacy row with precision beyond six decimals before the new guard.
insert into public.nx_deposit_submissions(user_id,asset_code,network_code,amount,tx_hash,status)
values ('10000000-0000-0000-0000-000000000301','USDT','TRON-TRC20',0.00000001,repeat('e',64),'submitted');
\i v2/supabase/migrations/014_usdt_deposit_six_decimal_precision.sql
\i v2/supabase/migrations/016_atomic_deposit_settlement.sql

DO $$
begin
  if not exists (select 1 from public.nx_deposit_submissions where tx_hash=repeat('e',64) and amount=0.00000001) then
    raise exception 'FAIL: legacy submission was modified or removed';
  end if;
end $$;

select set_config('request.jwt.claim.role','service_role',true);

do $$
declare
  v_id uuid;
  v_evidence jsonb;
  v_count integer;
  v_balance numeric;
  v_settlement jsonb;
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

  -- Six decimal places are accepted; precision beyond six is rejected.
  if public.nx_submit_deposit(
    '10000000-0000-0000-0000-000000000301',
    1.123456,'TRON-TRC20',repeat('f',64)
  ) is null then raise exception 'FAIL: valid six-decimal amount was rejected'; end if;

  begin
    perform public.nx_submit_deposit(
      '10000000-0000-0000-0000-000000000301',
      1.1234567,'TRON-TRC20',repeat('a',64)
    );
    raise exception 'FAIL: amount with seven decimal places was accepted';
  exception when others then
    if sqlerrm <> 'invalid amount' then raise; end if;
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

  begin
    perform public.nx_settle_verified_deposit(v_id,(v_evidence->>'evidence_id')::uuid,
      'TWrongContract','TConfiguredDeposit',20);
    raise exception 'FAIL: wrong token contract was settled';
  exception when others then
    if sqlerrm <> 'deposit verification evidence does not meet settlement policy' then raise; end if;
  end;
  begin
    perform public.nx_settle_verified_deposit(v_id,(v_evidence->>'evidence_id')::uuid,
      'TOfficialUSDT','TWrongRecipient',20);
    raise exception 'FAIL: wrong recipient was settled';
  exception when others then
    if sqlerrm <> 'deposit verification evidence does not meet settlement policy' then raise; end if;
  end;
  begin
    perform public.nx_settle_verified_deposit(v_id,(v_evidence->>'evidence_id')::uuid,
      'TOfficialUSDT','TConfiguredDeposit',21);
    raise exception 'FAIL: under-confirmed evidence was settled';
  exception when others then
    if sqlerrm <> 'deposit verification evidence does not meet settlement policy' then raise; end if;
  end;

  v_settlement := public.nx_settle_verified_deposit(v_id,(v_evidence->>'evidence_id')::uuid,
    'TOfficialUSDT','TConfiguredDeposit',20);
  if v_settlement->>'settled' <> 'true' or v_settlement->>'duplicate_retry' <> 'false' then
    raise exception 'FAIL: valid verified deposit did not settle';
  end if;
  select balance into v_balance from public.wallets
    where user_id='10000000-0000-0000-0000-000000000301';
  if v_balance <> 54.5 then raise exception 'FAIL: wallet not credited exactly once, got %',v_balance; end if;
  select count(*) into v_count from public.nx_wallet_ledger
    where reference_id=(v_settlement->>'deposit_id')::uuid and entry_type='deposit_credit';
  if v_count <> 1 then raise exception 'FAIL: expected exactly one deposit credit ledger entry'; end if;
  select count(*) into v_count from public.nx_deposits
    where id=(v_settlement->>'deposit_id')::uuid and status='credited'
      and ledger_id=(v_settlement->>'ledger_id')::uuid
      and verification_evidence_id=(v_evidence->>'evidence_id')::uuid;
  if v_count <> 1 then raise exception 'FAIL: credited deposit record is incomplete'; end if;
  if (select status from public.nx_deposit_submissions where id=v_id) <> 'credited' then
    raise exception 'FAIL: submission was not marked credited';
  end if;

  v_settlement := public.nx_settle_verified_deposit(v_id,(v_evidence->>'evidence_id')::uuid,
    'TOfficialUSDT','TConfiguredDeposit',20);
  if v_settlement->>'duplicate_retry' <> 'true' then raise exception 'FAIL: retry not idempotent'; end if;
  select balance into v_balance from public.wallets
    where user_id='10000000-0000-0000-0000-000000000301';
  select count(*) into v_count from public.nx_wallet_ledger
    where reference_id=(v_settlement->>'deposit_id')::uuid and entry_type='deposit_credit';
  if v_balance <> 54.5 or v_count <> 1 then
    raise exception 'FAIL: retry changed balance or duplicated ledger';
  end if;
  if has_function_privilege('authenticated',
       'public.nx_settle_verified_deposit(uuid,uuid,text,text,integer)','execute') then
    raise exception 'FAIL: authenticated role can execute settlement RPC';
  end if;
  select count(*) into v_count from public.nx_admin_audit_logs
    where action='deposit_credited_by_verified_evidence' and target_id=(v_settlement->>'deposit_id');
  if v_count <> 1 then raise exception 'FAIL: settlement audit missing or duplicated'; end if;

  raise notice 'PASS: evidence matching, immutable storage, atomic exactly-once settlement, policy enforcement, audit, and retry safety';
end $$;

rollback;
