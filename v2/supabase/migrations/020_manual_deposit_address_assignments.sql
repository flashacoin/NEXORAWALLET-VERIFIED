-- NEXORA V2: admin-assigned manual deposit instructions.
-- No payment provider, blockchain monitor, or automated address derivation is used.
-- Access is mediated by authenticated Edge Functions; the table remains RLS protected.
create table if not exists public.nx_deposit_addresses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  asset_code text not null default 'USDT',
  network_code text not null default 'TRON-TRC20',
  deposit_address text not null,
  payment_instructions text,
  is_active boolean not null default true,
  assigned_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint nx_deposit_addresses_asset_network_check
    check (asset_code ~ '^[A-Z0-9]{2,12}$' and network_code ~ '^[A-Z0-9-]{2,24}$'),
  constraint nx_deposit_addresses_value_check
    check (length(trim(deposit_address)) between 8 and 200),
  constraint nx_deposit_addresses_user_asset_network_unique
    unique (user_id, asset_code, network_code)
);

create index if not exists nx_deposit_addresses_active_lookup_idx
  on public.nx_deposit_addresses(user_id, asset_code, network_code)
  where is_active = true;

alter table public.nx_deposit_addresses enable row level security;

comment on table public.nx_deposit_addresses is
  'Admin-assigned deposit instructions for manual off-platform payments. No automatic payment verification.';
comment on column public.nx_deposit_addresses.deposit_address is
  'Address entered by an administrator; never generated or monitored by NEXORA.';
comment on column public.nx_deposit_addresses.payment_instructions is
  'Optional manual payment instructions displayed to the assigned user.';
