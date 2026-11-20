-- NEXORA V2: atomic wallet-funded order settlement (draft; isolated testing required)
-- Order lock serializes pay/cancel. Ledger debit and paid status and fulfillment job
-- are committed or rolled back together.

create or replace function public.nx_pay_order_with_wallet(
  p_order_id uuid,
  p_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.nx_payment_orders%rowtype;
  v_ledger_id uuid;
  v_key text;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'not authorized';
  end if;
  if p_order_id is null or p_user_id is null then
    raise exception 'order and user are required';
  end if;

  select * into v_order
    from public.nx_payment_orders
    where id = p_order_id
    for update;

  if not found then raise exception 'order not found'; end if;
  if v_order.user_id <> p_user_id then raise exception 'order owner mismatch'; end if;
  if v_order.provider <> 'wallet' or v_order.payment_method <> 'wallet' then
    raise exception 'order is not wallet payable';
  end if;

  -- Retry after a successful settlement is harmless.
  if v_order.status = 'paid' then
    return jsonb_build_object('ok', true, 'order_id', v_order.id, 'status', 'paid', 'reused', true);
  end if;
  if v_order.status <> 'pending' then raise exception 'order is not pending'; end if;
  if v_order.expires_at is not null and v_order.expires_at <= now() then
    update public.nx_payment_orders set status = 'expired', updated_at = now()
      where id = p_order_id;
    return jsonb_build_object('ok', false, 'order_id', v_order.id, 'status', 'expired');
  end if;
  if v_order.currency <> 'USDT' then raise exception 'wallet currency unsupported'; end if;

  v_key := 'wallet-pay:' || v_order.id::text;
  v_ledger_id := public.nx_post_ledger_entry(
    p_user_id, v_order.currency, -v_order.amount, 'payment_debit',
    v_key, 'payment_order', v_order.id,
    jsonb_build_object('order_id', v_order.id, 'product_code', v_order.product_code)
  );

  update public.nx_payment_orders
    set status = 'paid', paid_at = now(), payment_verified_at = now(),
        fulfillment_key = 'fulfill:' || v_order.id::text,
        fulfillment_status = 'queued', updated_at = now(), version = version + 1
    where id = v_order.id;

  insert into public.nx_fulfillment_jobs(order_id, fulfillment_key, job_status)
    values (v_order.id, 'fulfill:' || v_order.id::text, 'queued')
    on conflict (order_id) do nothing;

  return jsonb_build_object('ok', true, 'order_id', v_order.id, 'status', 'paid',
    'ledger_id', v_ledger_id, 'reused', false);
end;
$$;

revoke all on function public.nx_pay_order_with_wallet(uuid,uuid) from public, anon, authenticated;
grant execute on function public.nx_pay_order_with_wallet(uuid,uuid) to service_role;
