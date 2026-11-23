// NEXORA V2: admin-triggered deposit settlement from immutable verifier evidence.
// Amount, user, contract, recipient, and confirmation policy are never accepted from browser input.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization,apikey,content-type",
  "Access-Control-Allow-Methods": "POST,OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const admins = (Deno.env.get("NEXORA_ADMIN_USER_IDS") ?? "").split(",").map((x) => x.trim()).filter(Boolean);
  const tokenContract = Deno.env.get("NEXORA_USDT_CONTRACT");
  const depositRecipient = Deno.env.get("NEXORA_DEPOSIT_ADDRESS");
  const requiredConfirmations = Number(Deno.env.get("NEXORA_DEPOSIT_CONFIRMATIONS") ?? "");
  if (!url || !anon || !service || admins.length === 0 || !tokenContract || !depositRecipient ||
      !Number.isSafeInteger(requiredConfirmations) || requiredConfirmations < 1) {
    return json({ error: "Deposit settlement is not configured" }, 503);
  }

  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) return json({ error: "Authentication required" }, 401);
  let authResponse: Response;
  try {
    authResponse = await fetch(url + "/auth/v1/user", {
      headers: { apikey: anon, Authorization: authorization }, signal: AbortSignal.timeout(10_000),
    });
  } catch { return json({ error: "Authentication service unavailable" }, 503); }
  if (!authResponse.ok) return json({ error: "Invalid session" }, 401);
  const user = await authResponse.json();
  if (!admins.includes(user?.id)) return json({ error: "Administrator access required" }, 403);

  let body: { submission_id?: unknown; evidence_id?: unknown };
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON" }, 400); }
  const submissionId = typeof body.submission_id === "string" ? body.submission_id : "";
  const evidenceId = typeof body.evidence_id === "string" ? body.evidence_id : "";
  if (!UUID.test(submissionId) || !UUID.test(evidenceId)) {
    return json({ error: "Valid submission_id and evidence_id are required" }, 400);
  }

  try {
    const response = await fetch(url + "/rest/v1/rpc/nx_settle_verified_deposit", {
      method: "POST",
      headers: { apikey: service, Authorization: "Bearer " + service, "Content-Type": "application/json" },
      body: JSON.stringify({
        p_submission_id: submissionId, p_evidence_id: evidenceId,
        p_expected_token_contract: tokenContract, p_expected_recipient: depositRecipient,
        p_required_confirmations: requiredConfirmations,
      }),
      signal: AbortSignal.timeout(12_000),
    });
    const result = await response.json().catch(() => null);
    if (!response.ok || !result || result.settled !== true ||
        typeof result.deposit_id !== "string" || typeof result.ledger_id !== "string") {
      return json({ error: "Deposit settlement was not completed. Keep the submission under manual review." }, 409);
    }
    return json({ settlement_status: "credited", duplicate_retry: result.duplicate_retry === true,
      deposit_id: result.deposit_id, ledger_id: result.ledger_id,
      warning: "Settlement was performed only from previously recorded immutable verifier evidence." });
  } catch {
    return json({ error: "Settlement service unavailable; verify database state before retrying." }, 503);
  }
});
