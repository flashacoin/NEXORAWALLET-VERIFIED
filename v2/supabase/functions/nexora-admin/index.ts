import { verifyWithdrawalTransfer, withdrawalAmountToBaseUnits } from "./nexora-withdrawal-verifier.ts";
import { tronAddressToHex } from "../nexora-deposit-verify-preview/tron-provider-normalizer.ts";
// NEXORA Wallet V2 Admin API — authenticated admin endpoint.
// Read actions plus withdrawal review RPCs (approve/reject/record manual payout).
// This endpoint does not broadcast or transfer funds.
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const adminIdsRaw = Deno.env.get("NEXORA_ADMIN_USER_IDS") ?? "";
  if (!url || !anon || !service || !adminIdsRaw) return json({ error: "Server configuration incomplete" }, 500);

  const bearer = req.headers.get("Authorization") ?? "";
  if (!bearer.startsWith("Bearer ")) return json({ error: "Authentication required" }, 401);
  const token = bearer.slice(7);

  let authResponse: Response;
  try {
    authResponse = await fetch(`${url}/auth/v1/user`, {
      headers: { apikey: anon, Authorization: `Bearer ${token}` },
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    return json({ error: "Authentication service unavailable" }, 503);
  }
  if (!authResponse.ok) return json({ error: "Invalid or expired session" }, 401);
  const authUser = await authResponse.json();
  const userId = authUser?.id;
  if (!userId) return json({ error: "Invalid authenticated user" }, 401);

  // Admin IDs are configured as a server secret; never trust a client role or email.
  const adminIds = adminIdsRaw.split(",").map((v) => v.trim()).filter(Boolean);
  if (!adminIds.includes(userId)) return json({ error: "Administrator access required" }, 403);

  let body: { action?: string; withdrawal_id?: string; reason?: string; tx_hash?: string; review_action?: string; page?: number; page_size?: number; search?: string };
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON" }, 400); }
  const action = body.action;

  const headers = {
    apikey: service,
    Authorization: `Bearer ${service}`,
    "Content-Type": "application/json",
  };
  const query = async (table: string, params: string) => {
    const r = await fetch(`${url}/rest/v1/${table}?${params}`, { headers, signal: AbortSignal.timeout(12_000) });
    if (!r.ok) throw new Error("Admin data query failed");
    return r.json();
  };

  try {
    // Withdrawal state transitions: service-role RPCs only, admin identity comes from verified JWT.
    if (["withdrawal_approve","withdrawal_reject","withdrawal_complete"].includes(action ?? "")) {
      const withdrawalId = typeof body.withdrawal_id === "string" ? body.withdrawal_id.trim() : "";
      if (!/^[0-9a-f-]{36}$/i.test(withdrawalId)) return json({ error: "Invalid withdrawal ID" }, 400);
      let rpcName = "nx_admin_review_withdrawal";
      let rpcArgs: Record<string, unknown> = { p_withdrawal_id: withdrawalId, p_admin_user_id: userId };
      if (action === "withdrawal_approve") rpcArgs.p_action = "approve";
      if (action === "withdrawal_reject") {
        const reason = typeof body.reason === "string" ? body.reason.trim() : "";
        if (reason.length < 3 || reason.length > 500) return json({ error: "Rejection reason must be 3-500 characters" }, 400);
        rpcArgs.p_action = "reject"; rpcArgs.p_rejection_reason = reason;
      }
      if (action === "withdrawal_complete") {
        const txHash = typeof body.tx_hash === "string" ? body.tx_hash.trim().toLowerCase() : "";
        if (!/^[a-f0-9]{64}$/.test(txHash)) return json({ error: "Invalid TRON transaction hash" }, 400);
        const gridKey = Deno.env.get("TRONGRID_API_KEY");
        const tokenContract = Deno.env.get("NEXORA_USDT_CONTRACT");
        const minConfirmations = Number(Deno.env.get("NEXORA_WITHDRAWAL_CONFIRMATIONS") ?? "");
        const tronGridBase = (Deno.env.get("TRONGRID_BASE_URL") ?? "https://api.trongrid.io").replace(/\/+$/, "");
        if (!gridKey || !tokenContract || !Number.isSafeInteger(minConfirmations) || minConfirmations < 1) {
          return json({ error: "Withdrawal chain verification is not configured; request remains in processing." }, 503);
        }
        try { await tronAddressToHex(tokenContract); } catch {
          return json({ error: "Configured USDT contract address is invalid." }, 503);
        }
        const rows = await query("nx_withdrawals",
          "select=id,asset_code,network_code,amount,fee_amount,status,destination_address&id=eq." + encodeURIComponent(withdrawalId) + "&limit=1");
        const withdrawal = rows[0];
        if (!withdrawal) return json({ error: "Withdrawal not found" }, 404);
        if (withdrawal.status !== "processing") return json({ error: "Withdrawal must be approved and processing before payout verification." }, 409);
        if (withdrawal.asset_code !== "USDT" || withdrawal.network_code !== "TRON-TRC20") return json({ error: "Unsupported withdrawal asset or network." }, 409);
        const amount = String(withdrawal.amount);
        if (!withdrawalAmountToBaseUnits(amount)) return json({ error: "Requested payout amount must use no more than six USDT decimal places." }, 409);
        let verified;
        try {
          verified = await verifyWithdrawalTransfer({
            transactionId: txHash,
            tokenContractAddress: tokenContract,
            recipientAddress: String(withdrawal.destination_address),
            amount,
            minimumConfirmations: minConfirmations,
          }, { baseUrl: tronGridBase, apiKey: gridKey });
        } catch {
          return json({ error: "TRON verification service is unavailable or returned invalid evidence. Withdrawal remains in processing." }, 503);
        }
        if (!verified.ok) return json({ error: "Withdrawal was not completed: " + verified.reason + ". It remains in processing for manual review." }, 409);
        const evidenceResponse = await fetch(`${url}/rest/v1/rpc/nx_record_withdrawal_evidence`, {
          method: "POST", headers, body: JSON.stringify({
            p_withdrawal_id: withdrawalId,
            p_tx_hash: txHash,
            p_event_index: verified.evidence.eventIndex,
            p_token_contract_address: verified.evidence.contractAddress,
            p_sender_address: verified.evidence.from,
            p_recipient_address: verified.evidence.to,
            p_amount_base_units: verified.amountBaseUnits,
            p_block_number: verified.evidence.blockNumber,
            p_confirmations: verified.evidence.confirmations,
            p_receipt_result: verified.evidence.receiptResult,
            p_verifier_version: "tron-solidified-withdrawal-v1",
          }), signal: AbortSignal.timeout(12_000),
        });
        const evidenceResult = await evidenceResponse.json().catch(() => null);
        if (!evidenceResponse.ok || !evidenceResult?.recorded) {
          return json({ error: "Verified chain evidence could not be safely stored; withdrawal remains in processing." }, 409);
        }
        rpcName = "nx_admin_complete_withdrawal"; rpcArgs.p_tx_hash = txHash;
      }
      const rpcResponse = await fetch(`${url}/rest/v1/rpc/${rpcName}`, {
        method: "POST", headers, body: JSON.stringify(rpcArgs), signal: AbortSignal.timeout(12_000),
      });
      const rpcData = await rpcResponse.json().catch(() => null);
      if (!rpcResponse.ok) return json({ error: typeof rpcData === "string" ? rpcData : "Withdrawal action rejected by database" }, rpcResponse.status >= 400 && rpcResponse.status < 600 ? rpcResponse.status : 400);
      return json({ success: true, result: rpcData });
    }
    if (action === "overview") {
      const [users, wallets, deposits, withdrawals] = await Promise.all([
        query("profiles", "select=id,email,display_name,created_at&order=created_at.desc&limit=100"),
        query("wallets", "select=id,user_id,asset_code,balance,updated_at&order=updated_at.desc&limit=500"),
        query("nx_deposits", "select=id,user_id,asset_code,network_code,amount,status,tx_hash,created_at&order=created_at.desc&limit=100"),
        query("nx_withdrawals", "select=id,user_id,asset_code,network_code,amount,fee_amount,status,destination_address,tx_hash,created_at&order=created_at.desc&limit=100"),
      ]);
      return json({ users, wallets, deposits, withdrawals });
    }
    if (action === "users") {
      const page = Number(body.page ?? 1);
      const pageSize = Number(body.page_size ?? 50);
      const search = typeof body.search === "string" ? body.search.trim().slice(0, 120) : "";
      if (!Number.isInteger(page) || page < 1 || page > 10000) return json({ error: "Invalid page" }, 400);
      if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > 100) return json({ error: "Invalid page size" }, 400);
      if (search && !/^[a-zA-Z0-9@._+ -]+$/.test(search)) return json({ error: "Search contains unsupported characters" }, 400);
      const params = ["select=id,email,display_name,created_at","order=created_at.desc,id.desc","limit="+(pageSize+1),"offset="+((page-1)*pageSize)];
      if (search) {
        if (/^[0-9a-f-]{36}$/i.test(search)) params.push("id=eq."+encodeURIComponent(search));
        else params.push("or=(email.ilike.*"+encodeURIComponent(search)+"*,display_name.ilike.*"+encodeURIComponent(search)+"*)");
      }
      const fetched = await query("profiles", params.join("&"));
      const hasMore = fetched.length > pageSize;
      const users = fetched.slice(0,pageSize);
      const ids = users.map((u: {id:string}) => u.id).filter((id: string) => /^[0-9a-f-]{36}$/i.test(id));
      const wallets = ids.length ? await query("wallets", "select=id,user_id,asset_code,balance,updated_at&user_id=in.("+ids.map(encodeURIComponent).join(",")+")&order=asset_code.asc") : [];
      return json({ users, wallets, page, page_size: pageSize, has_more: hasMore });
    }
    // Bounded, stable pagination for admin queues. Fetch one extra row to
    // determine whether a next page exists without a separate count query.
    const listPage = async (table: string) => {
      const page = Number(body.page ?? 1);
      const pageSize = Number(body.page_size ?? 50);
      if (!Number.isInteger(page) || page < 1 || page > 10000) return { error: "Invalid page" };
      if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > 100) return { error: "Invalid page size" };
      const fetched = await query(table,
        "select=*&order=created_at.desc,id.desc&limit=" + (pageSize + 1) +
        "&offset=" + ((page - 1) * pageSize));
      return { rows: fetched.slice(0, pageSize), page, page_size: pageSize, has_more: fetched.length > pageSize };
    };
    if (action === "deposits") {
      const result = await listPage("nx_deposits");
      if ("error" in result) return json({ error: result.error }, 400);
      return json({ deposits: result.rows, page: result.page, page_size: result.page_size, has_more: result.has_more });
    }
    if (action === "deposit_submissions") {
      const result = await listPage("nx_deposit_submissions");
      if ("error" in result) return json({ error: result.error }, 400);
      return json({ submissions: result.rows, page: result.page, page_size: result.page_size, has_more: result.has_more });
    }
    if (action === "withdrawals") {
      const result = await listPage("nx_withdrawals");
      if ("error" in result) return json({ error: result.error }, 400);
      return json({ withdrawals: result.rows, page: result.page, page_size: result.page_size, has_more: result.has_more });
    }
    if (action === "settings") {
      const settings = await query("nx_wallet_settings", "select=setting_key,setting_value,updated_by,updated_at&order=setting_key.asc");
      return json({ settings });
    }
    if (action === "ledger") {
      const page = Number((body as any).page ?? 1);
      const pageSize = Number((body as any).page_size ?? 50);
      const userId = typeof (body as any).user_id === "string" ? (body as any).user_id.trim() : "";
      const entryType = typeof (body as any).entry_type === "string" ? (body as any).entry_type.trim() : "";
      if (!Number.isInteger(page) || page < 1 || page > 10000) return json({ error: "Invalid page" }, 400);
      if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > 100) return json({ error: "Invalid page size" }, 400);
      if (userId && !/^[0-9a-f-]{36}$/i.test(userId)) return json({ error: "Invalid user ID" }, 400);
      const allowedTypes = ["deposit_credit","withdrawal_debit","withdrawal_refund","payment_debit","payment_refund","admin_adjustment","transfer_debit","transfer_credit","opening_balance"];
      if (entryType && !allowedTypes.includes(entryType)) return json({ error: "Invalid entry type" }, 400);
      const filters = ["select=id,user_id,wallet_id,asset_code,amount,entry_type,reference_type,reference_id,metadata,created_at","order=created_at.desc,id.desc","limit="+(pageSize+1),"offset="+((page-1)*pageSize)];
      if (userId) filters.push("user_id=eq."+encodeURIComponent(userId));
      if (entryType) filters.push("entry_type=eq."+encodeURIComponent(entryType));
      const fetched = await query("nx_wallet_ledger", filters.join("&"));
      const hasMore = fetched.length > pageSize;
      const ledger = fetched.slice(0,pageSize);
      return json({ ledger, page, page_size: pageSize, has_more: hasMore });
    }
    if (action === "audit") {
      const page = Number(body.page ?? 1);
      const pageSize = Number(body.page_size ?? 50);
      if (!Number.isInteger(page) || page < 1 || page > 10000) return json({ error: "Invalid page" }, 400);
      if (!Number.isInteger(pageSize) || pageSize < 1 || pageSize > 100) return json({ error: "Invalid page size" }, 400);
      const fetched = await query("nx_admin_audit_logs",
        "select=id,admin_user_id,action,target_type,target_id,before_data,after_data,created_at&order=created_at.desc,id.desc&limit=" +
        (pageSize + 1) + "&offset=" + ((page - 1) * pageSize));
      return json({ audit: fetched.slice(0, pageSize), page, page_size: pageSize, has_more: fetched.length > pageSize });
    }
    return json({ error: "Unknown action" }, 400);
  } catch {
    return json({ error: "Admin service unavailable; verify V2 database migration first" }, 503);
  }
});
