// NEXORA V2 withdrawal submission endpoint. No client-supplied fee or user ID is trusted.
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !service) return json({ error: "Server configuration incomplete" }, 500);
  const bearer = req.headers.get("Authorization") ?? "";
  if (!bearer.startsWith("Bearer ")) return json({ error: "Sign in required" }, 401);
  const token = bearer.slice(7);
  let auth: Response;
  try {
    auth = await fetch(url + "/auth/v1/user", { headers: { apikey: anon, Authorization: "Bearer " + token } });
  } catch {
    return json({ error: "Authentication service unavailable" }, 503);
  }
  if (!auth.ok) return json({ error: "Invalid or expired session" }, 401);
  const user = await auth.json();
  if (!user?.id) return json({ error: "Invalid session user" }, 401);
  let body: { amount?: unknown; destination_address?: unknown; idempotency_key?: unknown; network_code?: unknown };
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON body" }, 400); }
  const amount = Number(body.amount);
  const address = typeof body.destination_address === "string" ? body.destination_address.trim() : "";
  const key = typeof body.idempotency_key === "string" ? body.idempotency_key.trim() : "";
  const network = typeof body.network_code === "string" ? body.network_code : "TRON-TRC20";
  // Financial limits/fees must be explicitly configured. Fail closed when absent.
  const minRaw = Deno.env.get("NEXORA_WITHDRAW_MIN");
  const maxRaw = Deno.env.get("NEXORA_WITHDRAW_MAX");
  const feeBpsRaw = Deno.env.get("NEXORA_WITHDRAW_FEE_BPS");
  const fixedFeeRaw = Deno.env.get("NEXORA_WITHDRAW_FIXED_FEE");
  if ([minRaw, maxRaw, feeBpsRaw, fixedFeeRaw].some((v) => v == null || v.trim() === "")) {
    return json({ error: "Withdrawal settings are not configured. Withdrawals are temporarily disabled." }, 503);
  }
  const min = Number(minRaw);
  const max = Number(maxRaw);
  const feeBps = Number(feeBpsRaw);
  const fixedFee = Number(fixedFeeRaw);
  if (!Number.isFinite(amount) || amount <= 0 || amount !== Math.round(amount * 1e8) / 1e8) return json({ error: "Amount must be a positive number with up to 8 decimal places" }, 400);
  if (amount < min || amount > max) return json({ error: `Withdrawal amount must be between ${min} and ${max} USDT` }, 400);
  if (network !== "TRON-TRC20") return json({ error: "Only USDT on TRON TRC20 is supported currently" }, 400);
  if (!/^T[1-9A-HJ-NP-Za-km-z]{33}$/.test(address)) return json({ error: "Invalid TRON address format" }, 400);
  if (key.length < 8 || key.length > 200) return json({ error: "A valid idempotency key is required" }, 400);
  if (![min,max,feeBps,fixedFee].every(Number.isFinite) || min <= 0 || max < min || feeBps < 0 || feeBps > 10000 || fixedFee < 0) return json({ error: "Withdrawal configuration invalid" }, 500);
  const fee = Math.round((amount * feeBps / 10000 + fixedFee) * 1e8) / 1e8;
  const headers = { apikey: service, Authorization: "Bearer " + service, "Content-Type": "application/json" };
  const rpc = await fetch(url + "/rest/v1/rpc/nx_request_withdrawal", { method: "POST", headers, body: JSON.stringify({
    p_user_id: user.id, p_amount: amount, p_fee: fee, p_network_code: network, p_destination_address: address, p_idempotency_key: key
  })});
  const result = await rpc.json().catch(() => null);
  if (!rpc.ok) {
    const message = typeof result === "string" ? result : (result?.message || result?.details || "Withdrawal request could not be created");
    const status = /insufficient|balance/i.test(String(message)) ? 409 : 400;
    return json({ error: message }, status);
  }
  return json({ success: true, withdrawal_id: result, amount, fee, total_reserved: Math.round((amount + fee) * 1e8) / 1e8, status: "requested", network_code: network });
});
