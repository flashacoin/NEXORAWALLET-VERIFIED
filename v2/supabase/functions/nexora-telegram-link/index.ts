import { verifyTelegramInitData } from "./telegram-init-data.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization,apikey,content-type",
  "Access-Control-Allow-Methods": "POST,OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const botToken = Deno.env.get("TELEGRAM_BOT_TOKEN");
  if (!url || !anon || !service || !botToken) {
    return json({ error: "Telegram account linking is not configured on the server." }, 503);
  }

  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return json({ error: "Wallet sign-in required." }, 401);

  let authResponse: Response;
  try {
    authResponse = await fetch(url + "/auth/v1/user", {
      headers: { apikey: anon, Authorization: authorization },
      signal: AbortSignal.timeout(10000),
    });
  } catch {
    return json({ error: "Wallet authentication service unavailable." }, 503);
  }
  if (!authResponse.ok) return json({ error: "Wallet session is invalid or expired." }, 401);
  const walletUser = await authResponse.json();
  if (typeof walletUser?.id !== "string") return json({ error: "Invalid wallet account." }, 401);

  let body: { init_data?: unknown };
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON body." }, 400); }
  if (typeof body.init_data !== "string") return json({ error: "Telegram Mini App initData is required." }, 400);

  let telegramUser;
  try {
    telegramUser = await verifyTelegramInitData(body.init_data, botToken);
  } catch (error) {
    const reason = error instanceof Error ? error.message : "telegram_verification_failed";
    return json({ error: reason }, 401);
  }

  try {
    const response = await fetch(url + "/rest/v1/rpc/nx_link_telegram_account", {
      method: "POST",
      headers: {
        apikey: service,
        Authorization: "Bearer " + service,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        p_user_id: walletUser.id,
        p_telegram_user_id: telegramUser.id,
        p_username: telegramUser.username ?? null,
        p_first_name: telegramUser.first_name ?? null,
        p_last_name: telegramUser.last_name ?? null,
      }),
      signal: AbortSignal.timeout(12000),
    });
    const result = await response.json().catch(() => null);
    if (!response.ok) {
      const detail = typeof result === "string" ? result : result?.message;
      if (typeof detail === "string" && detail.includes("already linked")) {
        return json({ error: detail }, 409);
      }
      return json({ error: "Telegram account could not be linked. No wallet data was changed." }, 409);
    }
    if (!result || result.linked !== true) return json({ error: "Telegram link was not confirmed." }, 409);
    return json({
      linked: true,
      already_linked: result.already_linked === true,
      telegram_user_id: telegramUser.id,
      message: result.already_linked === true ? "This Telegram account is already linked to your wallet." : "Telegram account linked successfully.",
    });
  } catch {
    return json({ error: "Telegram linking service unavailable." }, 503);
  }
});
