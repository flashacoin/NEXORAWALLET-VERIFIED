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

  let body: { action?: string };
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
    if (action === "audit") {
      const audit = await query("nx_admin_audit_logs", "select=id,admin_user_id,action,target_type,target_id,before_data,after_data,created_at&order=created_at.desc&limit=200");
      return json({ audit });
    }
    return json({ error: "Unknown action" }, 400);
  } catch {
    return json({ error: "Admin service unavailable; verify V2 database migration first" }, 503);
  }
});
