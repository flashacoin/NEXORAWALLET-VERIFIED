// NEXORA V2 order API — authenticated create/read/cancel skeleton.
 // Requires draft migrations 001 + 002 to be reviewed and applied in an isolated project.
 // This function does NOT verify payments or fulfill services.
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
  const authResponse = await fetch(url + "/auth/v1/user", {
    headers: { apikey: anon, Authorization: "Bearer " + token },
  });
  if (!authResponse.ok) return fail(401, "Invalid or expired session");
  const user = await authResponse.json();
  if (!user?.id) return fail(401, "Invalid session user");

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return fail(400, "Invalid JSON");
  }
  const action = body.action;
  const headers = { apikey: service, Authorization: "Bearer " + service, "Content-Type": "application/json" };
  const db = async (path: string, init?: RequestInit) => fetch(url + "/rest/v1/" + path, { ...init, headers: { ...headers, ...(init?.headers ?? {}) } });

  try {
    if (action === "create") {
      const productCode = typeof body.product_code === "string" ? body.product_code.trim() : "";
      const method = typeof body.payment_method === "string" ? body.payment_method : "";
      const key = typeof body.idempotency_key === "string" ? body.idempotency_key.trim() : "";
      if (!/^[a-zA-Z0-9_-]{2,80}$/.test(productCode)) return fail(400, "Invalid product code");
      if (!["wallet", "tron", "telegram_stars"].includes(method)) return fail(400, "Unsupported payment method");
      if (key.length < 8 || key.length > 200) return fail(400, "Invalid idempotency key");

      // Prices and enabled methods are configured server-side. Client cannot provide amount.
      const settingsRes = await db("nx_wallet_settings?setting_key=eq.product_catalog&select=setting_value");
      if (!settingsRes.ok) return fail(503, "Catalog unavailable");
      const settings = await settingsRes.json();
      const catalog = settings?.[0]?.setting_value ?? {};
      const item = catalog?.[productCode];
      if (!item || item.active !== true || !item.methods?.includes(method)) return fail(400, "Product or payment method unavailable");
      const price = Number(item.price);
      const currency = method === "telegram_stars" ? "XTR" : (item.currency ?? "USDT");
      if (!Number.isFinite(price) || price <= 0 || !["USDT", "XTR"].includes(currency)) return fail(503, "Catalog configuration invalid");
      if (method === "telegram_stars" && currency !== "XTR") return fail(503, "Stars catalog currency invalid");
      if (method === "tron" && currency !== "USDT") return fail(503, "TRON catalog currency invalid");
      const expiresAt = new Date(Date.now() + 15 * 60 * 1000).toISOString();

      // Existing idempotent order: return it only when request snapshot matches.
      const priorRes = await db("nx_payment_orders?idempotency_key=eq." + encodeURIComponent(key) + "&select=id,user_id,product_code,amount,currency,provider,status,expires_at,payment_method");
      if (!priorRes.ok) return fail(503, "Order lookup unavailable");
      const prior = (await priorRes.json())?.[0];
      if (prior) {
        if (prior.user_id !== user.id || prior.product_code !== productCode || Number(prior.amount) !== price || prior.payment_method !== method)
          return fail(409, "Idempotency key already used for another order");
        return json({ order: prior, reused: true });
      }

      const provider = method === "wallet" ? "wallet" : method === "tron" ? "tron" : "telegram_stars";
      const insertRes = await db("nx_payment_orders", {
        method: "POST",
        body: JSON.stringify({
          user_id: user.id,
          product_code: productCode,
          description: String(item.description ?? productCode).slice(0, 200),
          currency,
          amount: price,
          status: "pending",
          provider,
          payment_method: method,
          network_code: method === "tron" ? "TRON-TRC20" : null,
          idempotency_key: key,
          expires_at: expiresAt,
          metadata: { quantity: 1, price_snapshot: price, catalog_version: item.version ?? null },
        }),
        headers: { Prefer: "return=representation" },
      });
      if (insertRes.status === 409 || insertRes.status === 400) return fail(409, "Order key conflict");
      if (!insertRes.ok) return fail(503, "Order creation failed");
      const created = (await insertRes.json())?.[0];
      if (!created) return fail(503, "Order creation failed");
      return json({ order: created, reused: false }, 201);
    }

    if (action === "get") {
      const orderId = typeof body.order_id === "string" ? body.order_id : "";
      if (!/^[0-9a-f-]{36}$/i.test(orderId)) return fail(400, "Invalid order ID");
      const response = await db("nx_payment_orders?id=eq." + encodeURIComponent(orderId) + "&user_id=eq." + user.id + "&select=id,product_code,description,currency,amount,status,provider,payment_method,network_code,expires_at,paid_at,fulfilled_at,created_at,updated_at");
      if (!response.ok) return fail(503, "Order lookup unavailable");
      const rows = await response.json();
      if (!rows?.length) return fail(404, "Order not found");
      return json({ order: rows[0] });
    }

    if (action === "cancel") {
      const orderId = typeof body.order_id === "string" ? body.order_id : "";
      if (!/^[0-9a-f-]{36}$/i.test(orderId)) return fail(400, "Invalid order ID");
      const response = await db("nx_payment_orders?id=eq." + encodeURIComponent(orderId) + "&user_id=eq." + user.id + "&status=eq.pending&select=id,status", {
        method: "PATCH",
        body: JSON.stringify({ status: "cancelled", updated_at: new Date().toISOString() }),
        headers: { Prefer: "return=representation" },
      });
      if (!response.ok) return fail(503, "Cancellation unavailable");
      const rows = await response.json();
      if (!rows?.length) return fail(409, "Order cannot be cancelled");
      return json({ order: rows[0] });
    }

    return fail(400, "Unknown action");
  } catch {
    return fail(503, "Order service temporarily unavailable");
  }
});
