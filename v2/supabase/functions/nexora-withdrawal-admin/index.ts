// NEXORA V2 admin withdrawal operations. Admin UUID allowlist is mandatory.
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
  const allowlist = Deno.env.get("NEXORA_ADMIN_USER_IDS") ?? "";
  if (!url || !anon || !service || !allowlist) return json({ error: "Server configuration incomplete" }, 500);

  const bearer = req.headers.get("Authorization") ?? "";
  if (!bearer.startsWith("Bearer ")) return json({ error: "Authentication required" }, 401);
  const auth = await fetch(url + "/auth/v1/user", { headers: { apikey: anon, Authorization: bearer } });
  if (!auth.ok) return json({ error: "Invalid or expired session" }, 401);
  const user = await auth.json();
  const adminId = user?.id;
  if (!adminId || !allowlist.split(",").map((s) => s.trim()).includes(adminId))
    return json({ error: "Administrator access required" }, 403);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON" }, 400); }
  const headers = { apikey: service, Authorization: "Bearer " + service, "Content-Type": "application/json" };
  const rest = async (path: string, init?: RequestInit) => {
    const r = await fetch(url + path, { ...init, headers: { ...headers, ...(init?.headers ?? {}) } });
    const raw = await r.text();
    if (!r.ok) throw new Error("Admin withdrawal request failed");
    return raw ? JSON.parse(raw) : null;
  };
  try {
    if (body.action === "list") {
      const status = typeof body.status === "string" ? body.status : "";
      const allowed = ["requested","review","processing","completed","rejected","cancelled","failed"];
      if (status && !allowed.includes(status)) return json({ error: "Invalid status" }, 400);
      const params = new URLSearchParams({ select: "*", order: "created_at.desc", limit: "200" });
      if (status) params.set("status", "eq." + status);
      const withdrawals = await rest("/rest/v1/nx_withdrawals?" + params.toString());
      return json({ withdrawals });
    }
    if (body.action === "review") {
      const id = typeof body.withdrawal_id === "string" ? body.withdrawal_id : "";
      const action = body.review_action;
      if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: "Invalid withdrawal ID" }, 400);
      if (!["approve","reject"].includes(action)) return json({ error: "Invalid review action" }, 400);
      const reason = typeof body.reason === "string" ? body.reason.trim().slice(0,500) : null;
      const rpc = await rest("/rest/v1/rpc/nx_admin_review_withdrawal", { method: "POST", body: JSON.stringify({
        p_withdrawal_id: id, p_admin_user_id: adminId, p_action: action, p_rejection_reason: reason,
      }) });
      return json({ withdrawal: rpc });
    }
    if (body.action === "complete") {
      const id = typeof body.withdrawal_id === "string" ? body.withdrawal_id : "";
      const txHash = typeof body.tx_hash === "string" ? body.tx_hash.trim() : "";
      if (!/^[0-9a-f-]{36}$/i.test(id)) return json({ error: "Invalid withdrawal ID" }, 400);
      if (txHash.length < 20 || txHash.length > 160) return json({ error: "Invalid transaction hash" }, 400);
      const rpc = await rest("/rest/v1/rpc/nx_admin_complete_withdrawal", { method: "POST", body: JSON.stringify({
        p_withdrawal_id: id, p_admin_user_id: adminId, p_tx_hash: txHash,
      }) });
      return json({ withdrawal: rpc });
    }
    return json({ error: "Unknown action" }, 400);
  } catch {
    return json({ error: "Withdrawal admin service unavailable; verify V2 migrations are applied" }, 503);
  }
});
