-- NEXORA V2: serialize cancellation against wallet payment and external settlement.
-- Draft migration. Apply only after isolated review/testing.
create or replace function public.nx_cancel_payment_order(
  p_order_id uuid,
  p_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order public.nx_payment_orders%rowtype;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'not authorized';
  end if;
  if p_order_id is null or p_user_id is null then raise exception 'order and user required'; end if;
  select * into v_order from public.nx_payment_orders where id=p_order_id for update;
  if not found then raise exception 'order not found'; end if;
  if v_order.user_id <> p_user_id then raise exception 'order owner mismatch'; end if;
  if v_order.status = 'cancelled' then
    return jsonb_build_object('ok',true,'order_id',v_order.id,'status','cancelled','reused',true);
  end if;
  if v_order.status <> 'pending' then raise exception 'order cannot be cancelled'; end if;
  update public.nx_payment_orders set status='cancelled', updated_at=now(), version=version+1
    where id=p_order_id;
  return jsonb_build_object('ok',true,'order_id',v_order.id,'status','cancelled','reused',false);
end;
$$;
revoke all on function public.nx_cancel_payment_order(uuid,uuid) from public, anon, authenticated;
grant execute on function public.nx_cancel_payment_order(uuid,uuid) to service_role;
