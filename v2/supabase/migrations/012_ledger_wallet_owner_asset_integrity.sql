-- NEXORA V2: enforce ledger wallet ownership and asset consistency at the database layer.
-- Apply after 011 on staging. Validation intentionally fails if historical mismatches exist;
-- investigate those rows before retrying rather than silently rewriting financial history.

create unique index if not exists wallets_id_user_asset_unique
  on public.wallets(id, user_id, asset_code);

alter table public.nx_wallet_ledger
  add constraint nx_wallet_ledger_wallet_owner_asset_fk
  foreign key (wallet_id, user_id, asset_code)
  references public.wallets(id, user_id, asset_code)
  on delete restrict
  not valid;

alter table public.nx_wallet_ledger
  validate constraint nx_wallet_ledger_wallet_owner_asset_fk;
