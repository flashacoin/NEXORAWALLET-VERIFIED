-- NEXORA V2 wallet foundation (migration draft; review before applying)
-- Existing public.profiles, public.wallets and public.admin_users are reused.
-- All financial writes are server-side only.

create extension if not exists pgcrypto;

create table if not exists public.nx_wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  wallet_id uuid not null references public.wallets(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete restrict,
  asset_code text not null,
  amount numeric(30,10) not null check (amount <> 0),
  entry_type text not null check (entry_type in (
    'deposit_credit','withdrawal_debit','withdrawal_refund',
    'payment_debit','payment_refund','admin_adjustment','transfer_debit','transfer_credit'
  )),
  reference_type text,
  reference_id uuid,
  idempotency_key text not null unique,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists nx_wallet_ledger_user_created_idx
  on public.nx_wallet_ledger(user_id, created_at desc);
create index if not exists nx_wallet_ledger_wallet_created_idx
  on public.nx_wallet_ledger(wallet_id, created_at desc);

create table if not exists public.nx_deposits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  asset_code text not null default 'USDT',
  network_code text not null default 'TRON-TRC20',
  deposit_address text not null,
  tx_hash text,
  event_index integer not null default 0,
  amount numeric(30,10) not null check (amount > 0),
  confirmations integer not null default 0 check (confirmations >= 0),
  required_confirmations integer not null default 1 check (required_confirmations > 0),
  status text not null default 'detected' check (status in ('detected','confirming','confirmed','credited','ignored','reorged')),
  ledger_id uuid references public.nx_wallet_ledger(id),
  provider_event_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  credited_at timestamptz,
  unique(network_code, tx_hash, event_index)
);
create index if not exists nx_deposits_user_created_idx on public.nx_deposits(user_id, created_at desc);

create table if not exists public.nx_withdrawals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  asset_code text not null default 'USDT',
  network_code text not null default 'TRON-TRC20',
  destination_address text not null,
  amount numeric(30,10) not null check (amount > 0),
  fee_amount numeric(30,10) not null default 0 check (fee_amount >= 0),
  status text not null default 'requested' check (status in ('requested','review','approved','processing','completed','rejected','cancelled','failed')),
  ledger_debit_id uuid references public.nx_wallet_ledger(id),
  ledger_refund_id uuid references public.nx_wallet_ledger(id),
  tx_hash text,
  rejection_reason text,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists nx_withdrawals_user_created_idx on public.nx_withdrawals(user_id, created_at desc);

create table if not exists public.nx_payment_orders (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  product_code text not null,
  description text,
  currency text not null check (currency in ('USDT','XTR')),
  amount numeric(30,10) not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending','paid','failed','cancelled','refunded','expired')),
  provider text not null check (provider in ('wallet','tron','telegram_stars')),
  provider_charge_id text,
  idempotency_key text not null unique,
  paid_at timestamptz,
  fulfilled_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists nx_payment_provider_charge_unique
  on public.nx_payment_orders(provider, provider_charge_id)
  where provider_charge_id is not null;
create index if not exists nx_payment_orders_user_created_idx on public.nx_payment_orders(user_id, created_at desc);

create table if not exists public.nx_wallet_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  asset_code text not null default 'USDT',
  network_code text not null default 'TRON-TRC20',
  address text not null,
  provider_ref text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(user_id, asset_code, network_code)
);

create table if not exists public.nx_wallet_settings (
  setting_key text primary key,
  setting_value jsonb not null,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create table if not exists public.nx_admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  admin_user_id uuid references auth.users(id) on delete set null,
  action text not null,
  target_type text,
  target_id text,
  before_data jsonb,
  after_data jsonb,
  ip_hash text,
  created_at timestamptz not null default now()
);
create index if not exists nx_admin_audit_created_idx on public.nx_admin_audit_logs(created_at desc);

-- Enable RLS and deny direct client writes.
alter table public.nx_wallet_ledger enable row level security;
alter table public.nx_deposits enable row level security;
alter table public.nx_withdrawals enable row level security;
alter table public.nx_payment_orders enable row level security;
alter table public.nx_wallet_addresses enable row level security;
alter table public.nx_wallet_settings enable row level security;
alter table public.nx_admin_audit_logs enable row level security;

drop policy if exists "Users read own ledger" on public.nx_wallet_ledger;
create policy "Users read own ledger" on public.nx_wallet_ledger
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "Users read own deposits" on public.nx_deposits;
create policy "Users read own deposits" on public.nx_deposits
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "Users read own withdrawals" on public.nx_withdrawals;
create policy "Users read own withdrawals" on public.nx_withdrawals
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "Users read own payment orders" on public.nx_payment_orders;
create policy "Users read own payment orders" on public.nx_payment_orders
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "Users read own addresses" on public.nx_wallet_addresses;
create policy "Users read own addresses" on public.nx_wallet_addresses
  for select to authenticated using (user_id = (select auth.uid()));
drop policy if exists "Authenticated read wallet settings" on public.nx_wallet_settings;
create policy "Authenticated read wallet settings" on public.nx_wallet_settings
  for select to authenticated using (true);

-- No user-facing policy is created for audit logs, and no direct client write policy
-- is created on any financial table. Admin/service writes go through trusted backend.

grant select on public.nx_wallet_ledger, public.nx_deposits, public.nx_withdrawals,
  public.nx_payment_orders, public.nx_wallet_addresses, public.nx_wallet_settings
  to authenticated;
revoke insert, update, delete on public.nx_wallet_ledger, public.nx_deposits,
  public.nx_withdrawals, public.nx_payment_orders, public.nx_wallet_addresses,
  public.nx_wallet_settings, public.nx_admin_audit_logs from anon, authenticated;
grant all on public.nx_wallet_ledger, public.nx_deposits, public.nx_withdrawals,
  public.nx_payment_orders, public.nx_wallet_addresses, public.nx_wallet_settings,
  public.nx_admin_audit_logs to service_role;

-- Atomic server-only ledger posting. Positive amount credits, negative amount debits.
-- Idempotency key prevents duplicate credits/debits. This function does not decide
-- whether a blockchain deposit or payment is valid; the trusted backend must verify first.
create or replace function public.nx_post_ledger_entry(
  p_user_id uuid,
  p_asset_code text,
  p_amount numeric,
  p_entry_type text,
  p_idempotency_key text,
  p_reference_type text default null,
  p_reference_id uuid default null,
  p_metadata jsonb default '{}'::jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_wallet_id uuid;
  v_balance numeric;
  v_entry_id uuid;
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception 'not authorized';
  end if;
  if p_amount = 0 or p_amount is null then
    raise exception 'amount must be non-zero';
  end if;
  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 then
    raise exception 'idempotency key required';
  end if;

  select id, balance into v_wallet_id, v_balance
    from public.wallets
    where user_id = p_user_id and asset_code = p_asset_code
    for update;
  if v_wallet_id is null then
    raise exception 'wallet not found';
  end if;
  if v_balance + p_amount < 0 then
    raise exception 'insufficient balance';
  end if;

  insert into public.nx_wallet_ledger(
    wallet_id,user_id,asset_code,amount,entry_type,reference_type,reference_id,idempotency_key,metadata
  ) values (
    v_wallet_id,p_user_id,p_asset_code,p_amount,p_entry_type,p_reference_type,p_reference_id,
    p_idempotency_key,coalesce(p_metadata,'{}'::jsonb)
  )
  on conflict (idempotency_key) do nothing
  returning id into v_entry_id;

  if v_entry_id is null then
    select id into v_entry_id from public.nx_wallet_ledger where idempotency_key = p_idempotency_key;
    return v_entry_id;
  end if;

  update public.wallets
    set balance = balance + p_amount, updated_at = now()
    where id = v_wallet_id;
  return v_entry_id;
end;
$$;

revoke all on function public.nx_post_ledger_entry(uuid,text,numeric,text,text,text,uuid,jsonb) from public, anon, authenticated;
grant execute on function public.nx_post_ledger_entry(uuid,text,numeric,text,text,text,uuid,jsonb) to service_role;
