// NEXORA V2 deposit verification preview.
// Persists immutable matched evidence only. Never credits balances or changes submission status.
import { validateUsdtTransfer } from "./tron-usdt-transfer.ts";
import { normalizeSolidifiedTransferLogs, tronAddressToHex } from "./tron-provider-normalizer.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization,apikey,content-type",
  "Access-Control-Allow-Methods": "POST,OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function providerPost(baseUrl: string, path: string, gridKey: string, body: unknown): Promise<any> {
  const response = await fetch(baseUrl + path, {
    method: "POST",
    headers: {
      "TRON-PRO-API-KEY": gridKey,
      "Content-Type": "application/json",
      "Accept": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(12_000),
  });
  if (!response.ok) throw new Error("provider_http_error");
  const result = await response.json();
  if (!result || typeof result !== "object" || Array.isArray(result) || result.Error) {
    throw new Error("provider_invalid_response");
  }
  return result;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const admins = (Deno.env.get("NEXORA_ADMIN_USER_IDS") ?? "").split(",").map((x) => x.trim()).filter(Boolean);
  const gridKey = Deno.env.get("TRONGRID_API_KEY");
  const depositAddress = Deno.env.get("NEXORA_DEPOSIT_ADDRESS");
  const usdtContract = Deno.env.get("NEXORA_USDT_CONTRACT");
  const minConfirmations = Number(Deno.env.get("NEXORA_DEPOSIT_CONFIRMATIONS") ?? "");
  const tronGridBase = (Deno.env.get("TRONGRID_BASE_URL") ?? "https://api.trongrid.io").replace(/\/+$/, "");

  if (!url || !anon || !service || !admins.length || !gridKey || !depositAddress || !usdtContract ||
      !Number.isSafeInteger(minConfirmations) || minConfirmations < 1) {
    return json({ error: "Deposit verification is not configured" }, 503);
  }
  try {
    await tronAddressToHex(depositAddress);
    await tronAddressToHex(usdtContract);
  } catch {
    return json({ error: "Deposit verification address configuration is invalid" }, 503);
  }

  const auth = req.headers.get("Authorization") ?? "";
  if (!auth.startsWith("Bearer ")) return json({ error: "Authentication required" }, 401);
  let authResponse: Response;
  try {
    authResponse = await fetch(url + "/auth/v1/user", {
      headers: { apikey: anon, Authorization: auth },
      signal: AbortSignal.timeout(10_000),
    });
  } catch {
    return json({ error: "Authentication service unavailable" }, 503);
  }
  if (!authResponse.ok) return json({ error: "Invalid session" }, 401);
  const user = await authResponse.json();
  if (!admins.includes(user?.id)) return json({ error: "Admin permission required" }, 403);

  let body: { tx_hash?: string };
  try { body = await req.json(); } catch { return json({ error: "Invalid JSON" }, 400); }
  const hash = typeof body.tx_hash === "string" ? body.tx_hash.trim().toLowerCase() : "";
  if (!/^[a-f0-9]{64}$/.test(hash)) return json({ error: "Invalid transaction hash" }, 400);

  try {
    const [receipt, solidifiedHead] = await Promise.all([
      providerPost(tronGridBase, "/walletsolidity/gettransactioninfobyid", gridKey, { value: hash }),
      providerPost(tronGridBase, "/walletsolidity/getnowblock", gridKey, {}),
    ]);
    const solidifiedHeight = solidifiedHead.block_header?.raw_data?.number;
    if (!Number.isSafeInteger(solidifiedHeight) || solidifiedHeight < 0) {
      return json({ error: "TRON solidified block response is invalid" }, 502);
    }
    if (Object.keys(receipt).length === 0) {
      return json({
        verification_status: "manual_review_required",
        tx_hash: hash,
        matched_evidence: [],
        warning: "No solidified transaction receipt was found. No deposit has been verified or credited.",
      });
    }

    const normalized = await normalizeSolidifiedTransferLogs(
      receipt, hash, usdtContract, minConfirmations, solidifiedHeight,
    );
    const matchedEvidence: Array<{ evidence_id: string; event_index: number; amount_base_units: string; duplicate_retry: boolean }> = [];
    const unmatchedTransfers: Array<{ event_index: number; reason: string }> = [];
    const rejectedTransfers: Array<{ event_index: number; reason: string }> = [];

    // Sequential calls preserve deterministic matching and idempotent retries.
    for (const evidence of normalized) {
      const result = validateUsdtTransfer(evidence, {
        transactionId: hash,
        contractAddress: usdtContract,
        recipientAddress: depositAddress,
        minimumConfirmations: minConfirmations,
      });
      if (!result.ok) {
        rejectedTransfers.push({ event_index: evidence.eventIndex, reason: result.reason });
        continue;
      }

      const rpcResponse = await fetch(url + "/rest/v1/rpc/nx_record_deposit_evidence", {
        method: "POST",
        headers: {
          apikey: service,
          Authorization: "Bearer " + service,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          p_tx_hash: hash,
          p_event_index: evidence.eventIndex,
          p_token_contract_address: evidence.contractAddress,
          p_sender_address: evidence.from,
          p_recipient_address: evidence.to,
          p_amount_base_units: evidence.value,
          p_block_number: evidence.blockNumber,
          p_confirmations: evidence.confirmations,
          p_receipt_result: evidence.receiptResult,
          p_verifier_version: "tron-solidified-v1",
        }),
        signal: AbortSignal.timeout(12_000),
      });
      const rpcResult = await rpcResponse.json().catch(() => null);
      if (!rpcResponse.ok || !rpcResult || typeof rpcResult !== "object") {
        return json({ error: "Validated evidence could not be safely recorded; no deposit was credited." }, 503);
      }
      if (rpcResult.matched === true && typeof rpcResult.evidence_id === "string") {
        matchedEvidence.push({
          evidence_id: rpcResult.evidence_id,
          event_index: evidence.eventIndex,
          amount_base_units: evidence.value,
          duplicate_retry: rpcResult.duplicate_retry === true,
        });
      } else {
        unmatchedTransfers.push({
          event_index: evidence.eventIndex,
          reason: typeof rpcResult.reason === "string" ? rpcResult.reason : "submission_not_matched",
        });
      }
    }

    return json({
      verification_status: "manual_review_required",
      tx_hash: hash,
      solidified_block_height: solidifiedHeight,
      matched_evidence: matchedEvidence,
      unmatched_transfers: unmatchedTransfers,
      rejected_transfers: rejectedTransfers,
      warning: "Matched evidence is immutable and recorded for manual review only. Submission status, deposits, ledger entries, and wallet balances are unchanged; no deposit has been credited.",
    });
  } catch {
    return json({ error: "TRON verification provider unavailable or returned invalid evidence" }, 503);
  }
});
