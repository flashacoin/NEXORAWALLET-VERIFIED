// NEXORA Wallet V2 Admin API — authenticated read-only foundation.
// Mutating admin actions will be added only after DB migrations and approval workflows are tested.
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

  const authResponse = await fetch(`${url}/auth/v1/user`, {
    headers: { apikey: anon, Authorization: `Bearer ${token}` },
  });
  if (!authResponse.ok) return json({ error: "Invalid or expired session" }, 401);
  const authUser = await authResponse.json();
  const userId = authUser?.id;
  if (!userId) return json({ error: "Invalid authenticated user" }, 401);

  // Admin IDs are configured as a server secret; never trust a client role or email.
  const adminIds = adminIdsRaw.split(",").map((v) => v.trim()).filter(Boolean);
  if (!adminIds.includes(userId)) return json({ error: "Administrator access required" }, 403);

  let body: { action?: string; withdrawal_id?: string; reason?: string; tx_hash?: string; review_action?: string };
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON" }, 400); }
  const action = body.action;

  const headers = {
    apikey: service,
    Authorization: `Bearer ${service}`,
    "Content-Type": "application/json",
  };
  const query = async (table: string, params: string) => {
    const r = await fetch(`${url}/rest/v1/${table}?${params}`, { headers });
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
        const txHash = typeof body.tx_hash === "string" ? body.tx_hash.trim() : "";
        if (!/^[a-f0-9]{64}$/i.test(txHash)) return json({ error: "Invalid TRON transaction hash" }, 400);
        rpcName = "nx_admin_complete_withdrawal"; rpcArgs.p_tx_hash = txHash;
      }
      const rpcResponse = await fetch(`${url}/rest/v1/rpc/${rpcName}`, {
        method: "POST", headers, body: JSON.stringify(rpcArgs),
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
      const users = await query("profiles", "select=id,email,display_name,created_at&order=created_at.desc&limit=200");
      return json({ users });
    }
    if (action === "deposits") {
      const deposits = await query("nx_deposits", "select=*&order=created_at.desc&limit=200");
      return json({ deposits });
    }
    if (action === "withdrawals") {
      const withdrawals = await query("nx_withdrawals", "select=*&order=created_at.desc&limit=200");
      return json({ withdrawals });
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
      const filters = ["select=id,user_id,wallet_id,asset_code,amount,entry_type,reference_type,reference_id,metadata,created_at","order=created_at.desc","limit="+pageSize,"offset="+((page-1)*pageSize)];
      if (userId) filters.push("user_id=eq."+encodeURIComponent(userId));
      if (entryType) filters.push("entry_type=eq."+encodeURIComponent(entryType));
      const ledger = await query("nx_wallet_ledger", filters.join("&"));
      return json({ ledger, page, page_size: pageSize, has_more: ledger.length===pageSize });
    }
    if (action === "audit") {
      const audit = await query("nx_admin_audit_logs", "select=id,admin_user_id,action,target_type,target_id,before_data,after_data,created_at&order=created_at.desc&limit=200");
      return json({ audit });
    }
    return json({ error: "Unknown action" }, 400);
  } catch {
    return json({ error: "Admin service unavailable; verify V2 database migration first" }, 503);
  }
});
