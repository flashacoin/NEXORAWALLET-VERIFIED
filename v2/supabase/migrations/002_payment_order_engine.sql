-- NEXORA V2 payment order hardening (draft; do not apply to production)
-- Extends nx_payment_orders created by 001_wallet_ledger.sql.
-- All writes must originate from trusted server functions using service_role.

alter table public.nx_payment_orders
  add column if not exists expires_at timestamptz,
  add column if not exists payment_method text,
  add column if not exists network_code text,
  add column if not exists amount_received numeric(30,10),
  add column if not exists payment_verified_at timestamptz,
  add column if not exists fulfillment_key text,
  add column if not exists fulfillment_status text not null default 'not_started',
  add column if not exists failure_reason text,
  add column if not exists version integer not null default 1;

-- Payment events are immutable evidence; webhook/watcher retries deduplicate by source event.
create table if not exists public.nx_payment_events (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references public.nx_payment_orders(id) on delete restrict,
  provider text not null,
  provider_event_id text not null,
  event_type text not null,
  amount numeric(30,10),
  currency text,
  network_code text,
  tx_hash text,
  event_index integer,
  verification_status text not null default 'received'
    check (verification_status in ('received','verified','rejected','review')),
  raw_payload_hash text,
  rejection_reason text,
  received_at timestamptz not null default now(),
  verified_at timestamptz,
  unique(provider, provider_event_id)
);

create index if not exists nx_payment_events_order_received_idx
  on public.nx_payment_events(order_id, received_at desc);

-- Durable fulfillment queue prevents loss between settlement and service delivery.
create table if not exists public.nx_fulfillment_jobs (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.nx_payment_orders(id) on delete restrict,
  fulfillment_key text not null unique,
  job_status text not null default 'queued'
    check (job_status in ('queued','processing','completed','failed','cancelled')),
  attempts integer not null default 0 check (attempts >= 0),
  next_attempt_at timestamptz not null default now(),
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(order_id)
);

alter table public.nx_payment_events enable row level security;
alter table public.nx_fulfillment_jobs enable row level security;
-- No client-facing policies. Service role access only.
revoke insert, update, delete on public.nx_payment_events, public.nx_fulfillment_jobs from anon, authenticated;
grant all on public.nx_payment_events, public.nx_fulfillment_jobs to service_role;

-- Keep server-side writes restricted. Users can read their own order rows through
-- the existing RLS policy; no client policies are added for evidence/jobs.
