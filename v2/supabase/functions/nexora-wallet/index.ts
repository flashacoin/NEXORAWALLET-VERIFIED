// NEXORA Wallet V2 API — first secure read-only milestone.
// This endpoint intentionally does not create deposits, approve withdrawals,
// send funds, or alter balances. Those actions will be added only after
// server-side transaction workflows and authorization are tested.
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ??
    Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SERVICE_KEY) {
    return json({ error: "Server configuration incomplete" }, 500);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  if (!authHeader.startsWith("Bearer ")) return json({ error: "Authentication required" }, 401);
  const userToken = authHeader.slice(7);

  // Validate the supplied user JWT with Supabase Auth, rather than trusting its payload.
  const authRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${userToken}` },
  });
  if (!authRes.ok) return json({ error: "Invalid or expired session" }, 401);
  const authUser = await authRes.json();
  if (!authUser?.id) return json({ error: "Invalid session user" }, 401);

  let body: { action?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  const action = body.action;
  const userId = authUser.id;

  // Service-role reads are scoped explicitly to the verified user ID.
  const restHeaders = {
    apikey: SERVICE_KEY,
    Authorization: `Bearer ${SERVICE_KEY}`,
    "Content-Type": "application/json",
  };
  const rest = async (table: string, query: string) => {
    const response = await fetch(`${SUPABASE_URL}/rest/v1/${table}?${query}`, {
      headers: restHeaders,
    });
    if (!response.ok) throw new Error("Database request failed");
    return response.json();
  };

  try {
    if (action === "wallet") {
      const wallets = await rest("wallets", `select=id,asset_code,balance,updated_at&user_id=eq.${userId}&order=asset_code.asc`);
      return json({ wallets });
    }
    if (action === "history") {
      const ledger = await rest("nx_wallet_ledger", `select=id,asset_code,amount,entry_type,reference_type,created_at&user_id=eq.${userId}&order=created_at.desc&limit=100`);
      return json({ ledger });
    }
    if (action === "deposits") {
      const deposits = await rest("nx_deposits", `select=id,asset_code,network_code,amount,confirmations,required_confirmations,status,tx_hash,created_at&user_id=eq.${userId}&order=created_at.desc&limit=100`);
      return json({ deposits });
    }
    if (action === "deposit_submissions") {
      const submissions = await rest("nx_deposit_submissions", `select=id,asset_code,network_code,amount,tx_hash,status,admin_note,created_at,updated_at&user_id=eq.${userId}&order=created_at.desc&limit=100`);
      return json({ submissions });
    }
    if (action === "withdrawals") {
      const withdrawals = await rest("nx_withdrawals", `select=id,asset_code,network_code,destination_address,amount,fee_amount,status,tx_hash,rejection_reason,created_at,updated_at&user_id=eq.${userId}&order=created_at.desc&limit=100`);
      return json({ withdrawals });
    }
    return json({ error: "Unknown action" }, 400);
  } catch {
    return json({ error: "Wallet service temporarily unavailable" }, 503);
  }
});
