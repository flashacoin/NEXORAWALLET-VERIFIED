import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) return json({ error: "Server configuration missing" }, 500);

  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";
  if (!token) return json({ error: "Unauthorized" }, 401);

  const authClient = createClient(supabaseUrl, anonKey, { auth: { persistSession: false } });
  const { data: authData, error: authError } = await authClient.auth.getUser(token);
  if (authError || !authData.user) return json({ error: "Invalid session" }, 401);
  const userId = authData.user.id;

  let body: { action?: string };
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON" }, 400); }
  const action = body?.action;
  if (!["wallet", "history", "deposits", "withdrawals"].includes(action ?? "")) {
    return json({ error: "Unsupported action" }, 400);
  }

  const db = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });
  try {
    if (action === "wallet") {
      const { data, error } = await db.from("wallets").select("id,asset_code,balance,updated_at").eq("user_id", userId).order("asset_code");
      if (error) throw error;
      return json({ wallets: data ?? [] });
    }
    if (action === "history") {
      const { data, error } = await db.from("nx_wallet_ledger").select("id,asset_code,amount,entry_type,reference_type,reference_id,created_at").eq("user_id", userId).order("created_at", { ascending: false }).limit(50);
      if (error) throw error;
      return json({ ledger: data ?? [] });
    }
    if (action === "deposits") {
      const { data, error } = await db.from("nx_deposits").select("id,asset_code,network_code,amount,confirmations,required_confirmations,status,tx_hash,created_at,credited_at").eq("user_id", userId).order("created_at", { ascending: false }).limit(50);
      if (error) throw error;
      return json({ deposits: data ?? [] });
    }
    const { data, error } = await db.from("nx_withdrawals").select("id,asset_code,network_code,destination_address,amount,fee_amount,status,tx_hash,rejection_reason,created_at,updated_at").eq("user_id", userId).order("created_at", { ascending: false }).limit(50);
    if (error) throw error;
    return json({ withdrawals: data ?? [] });
  } catch (error) {
    console.error("nexora-wallet request failed", error);
    return json({ error: "Wallet data unavailable. Ensure V2 database migration is installed." }, 503);
  }
});
