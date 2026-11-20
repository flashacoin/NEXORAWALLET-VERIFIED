-- Isolated PostgreSQL integration test for migration 012.
-- Runs only in the disposable CI database; no Supabase or production data.

begin;

create table public.wallets (
  id uuid not null,
  user_id uuid not null,
  asset_code text not null
);

create table public.nx_wallet_ledger (
  id bigserial primary key,
  wallet_id uuid not null,
  user_id uuid not null,
  asset_code text not null
);

insert into public.wallets(id,user_id,asset_code) values
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','USDT'),
  ('00000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','USDT');

insert into public.nx_wallet_ledger(wallet_id,user_id,asset_code) values
  ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','USDT');

\i v2/supabase/migrations/012_ledger_wallet_owner_asset_integrity.sql

do $$
begin
  begin
    insert into public.nx_wallet_ledger(wallet_id,user_id,asset_code)
    values ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002','USDT');
    raise exception 'FAIL: mismatched wallet owner was accepted';
  exception when foreign_key_violation then
    raise notice 'PASS: mismatched wallet owner rejected';
  end;

  begin
    insert into public.nx_wallet_ledger(wallet_id,user_id,asset_code)
    values ('00000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','BTC');
    raise exception 'FAIL: mismatched asset was accepted';
  exception when foreign_key_violation then
    raise notice 'PASS: mismatched asset rejected';
  end;

  begin
    insert into public.nx_wallet_ledger(wallet_id,user_id,asset_code)
    values ('00000000-0000-0000-0000-000000000099','10000000-0000-0000-0000-000000000001','USDT');
    raise exception 'FAIL: unknown wallet was accepted';
  exception when foreign_key_violation then
    raise notice 'PASS: unknown wallet rejected';
  end;
end $$;

rollback;
