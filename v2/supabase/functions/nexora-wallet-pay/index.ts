// NEXORA V2 wallet payment endpoint.
// Authenticates the caller, then invokes the atomic settlement RPC with verified user ID.
// Requires reviewed migrations 001-003. Not deployed.
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
const fail = (status: number, error: string) => json({ error }, status);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return fail(405, "POST required");

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !service) return fail(500, "Server configuration incomplete");

  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return fail(401, "Authentication required");
  const token = authorization.slice(7);
  try {
    const authRes = await fetch(url + "/auth/v1/user", {
      headers: { apikey: anon, Authorization: "Bearer " + token },
    });
    if (!authRes.ok) return fail(401, "Invalid or expired session");
    const user = await authRes.json();
    if (!user?.id) return fail(401, "Invalid session user");

    let body: Record<string, unknown>;
    try { body = await req.json(); } catch { return fail(400, "Invalid JSON"); }
    const orderId = typeof body.order_id === "string" ? body.order_id.trim() : "";
    if (!/^[0-9a-f-]{36}$/i.test(orderId)) return fail(400, "Invalid order ID");

    const rpcRes = await fetch(url + "/rest/v1/rpc/nx_pay_order_with_wallet", {
      method: "POST",
      headers: {
        apikey: service,
        Authorization: "Bearer " + service,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ p_order_id: orderId, p_user_id: user.id }),
    });
    if (!rpcRes.ok) {
      // Keep database details out of the public response.
      if (rpcRes.status === 401 || rpcRes.status === 403) return fail(403, "Payment not authorized");
      return fail(409, "Wallet payment could not be completed");
    }
    const result = await rpcRes.json();
    if (result?.status === "expired") return json({ payment: result }, 409);
    return json({ payment: result });
  } catch {
    return fail(503, "Payment service temporarily unavailable");
  }
});
