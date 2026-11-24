// NEXORA V2 manual deposit-address service.
// Admins assign addresses manually; users can only read their own active instructions.
// This function never contacts a payment provider or blockchain.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply({ error: "POST required" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !service) return reply({ error: "Server configuration incomplete" }, 500);

  const bearer = req.headers.get("Authorization") ?? "";
  if (!bearer.startsWith("Bearer ")) return reply({ error: "Sign in required" }, 401);
  let authResponse: Response;
  try {
    authResponse = await fetch(url + "/auth/v1/user", {
      headers: { apikey: anon, Authorization: bearer },
      signal: AbortSignal.timeout(10000),
    });
  } catch {
    return reply({ error: "Authentication service unavailable" }, 503);
  }
  if (!authResponse.ok) return reply({ error: "Invalid or expired session" }, 401);
  const user = await authResponse.json().catch(() => null);
  if (!user?.id) return reply({ error: "Invalid user session" }, 401);

  let body: { action?: string; user_id?: string; asset_code?: string; network_code?: string; deposit_address?: string; payment_instructions?: string };
  try { body = await req.json(); } catch { return reply({ error: "Invalid JSON" }, 400); }

  const headers = {
    apikey: service,
    Authorization: "Bearer " + service,
    "Content-Type": "application/json",
    Prefer: "return=representation",
  };
  const adminIds = (Deno.env.get("NEXORA_ADMIN_USER_IDS") ?? "").split(",").map((v) => v.trim()).filter(Boolean);

  if (body.action === "assign") {
    if (!adminIds.includes(user.id)) return reply({ error: "Administrator access required" }, 403);
    const target = typeof body.user_id === "string" ? body.user_id.trim() : "";
    const asset = typeof body.asset_code === "string" ? body.asset_code.trim().toUpperCase() : "USDT";
    const network = typeof body.network_code === "string" ? body.network_code.trim().toUpperCase() : "TRON-TRC20";
    const address = typeof body.deposit_address === "string" ? body.deposit_address.trim() : "";
    const instructions = typeof body.payment_instructions === "string" ? body.payment_instructions.trim() : "";
    if (!/^[0-9a-f-]{36}$/i.test(target)) return reply({ error: "Enter a valid user ID" }, 400);
    if (!/^[A-Z0-9]{2,12}$/.test(asset) || !/^[A-Z0-9-]{2,24}$/.test(network)) return reply({ error: "Invalid asset or network" }, 400);
    if (address.length < 8 || address.length > 200) return reply({ error: "Deposit address must be 8-200 characters" }, 400);
    if (instructions.length > 1000) return reply({ error: "Payment instructions are too long" }, 400);

    const response = await fetch(url + "/rest/v1/nx_deposit_addresses?on_conflict=user_id,asset_code,network_code", {
      method: "POST",
      headers: { ...headers, Prefer: "resolution=merge-duplicates,return=representation" },
      body: JSON.stringify({
        user_id: target, asset_code: asset, network_code: network, deposit_address: address,
        payment_instructions: instructions || null, is_active: true, assigned_by: user.id, updated_at: new Date().toISOString(),
      }),
      signal: AbortSignal.timeout(15000),
    });
    const result = await response.json().catch(() => null);
    if (!response.ok) return reply({ error: "Could not save deposit address assignment" }, 400);
    await fetch(url + "/rest/v1/nx_admin_audit_logs", {
      method: "POST", headers,
      body: JSON.stringify({
        admin_user_id: user.id, action: "manual_deposit_address_assigned", target_type: "user",
        target_id: target, after_data: { asset_code: asset, network_code: network, address_last_four: address.slice(-4) },
      }),
      signal: AbortSignal.timeout(10000),
    });
    return reply({ success: true, assignment: Array.isArray(result) ? result[0] : result });
  }

  if (body.action === "my_address") {
    const asset = typeof body.asset_code === "string" ? body.asset_code.trim().toUpperCase() : "USDT";
    const network = typeof body.network_code === "string" ? body.network_code.trim().toUpperCase() : "TRON-TRC20";
    const response = await fetch(url + "/rest/v1/nx_deposit_addresses?select=asset_code,network_code,deposit_address,payment_instructions,updated_at&user_id=eq." +
      encodeURIComponent(user.id) + "&asset_code=eq." + encodeURIComponent(asset) + "&network_code=eq." +
      encodeURIComponent(network) + "&is_active=eq.true&limit=1", {
      headers, signal: AbortSignal.timeout(12000),
    });
    if (!response.ok) return reply({ error: "Could not load deposit instructions" }, 503);
    const rows = await response.json().catch(() => []);
    return reply({ assignment: rows[0] ?? null });
  }

  return reply({ error: "Unknown action" }, 400);
});
