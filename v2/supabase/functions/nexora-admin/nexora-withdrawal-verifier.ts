// Verify a manually broadcast TRON USDT withdrawal against solidified chain evidence.
// This module never broadcasts a transaction or moves funds.
import { normalizeSolidifiedTransferLogs } from "../nexora-deposit-verify-preview/tron-provider-normalizer.ts";
import { validateUsdtTransfer, type NormalizedTransferEvidence } from "../nexora-deposit-verify-preview/tron-usdt-transfer.ts";

export function withdrawalAmountToBaseUnits(amount: string): string | null {
  const match = /^(0|[1-9][0-9]*)(?:\.([0-9]{1,10}))?$/.exec(amount);
  if (!match) return null;
  const fraction = match[2] ?? "";
  if (fraction.length > 6 && /[1-9]/.test(fraction.slice(6))) return null;
  const units = (match[1] + fraction.slice(0, 6).padEnd(6, "0")).replace(/^0+(?=[0-9])/, "");
  return /^[1-9][0-9]*$/.test(units) ? units : null;
}

export type WithdrawalExpectation = {
  transactionId: string;
  tokenContractAddress: string;
  recipientAddress: string;
  amount: string;
  minimumConfirmations: number;
};

export type WithdrawalVerification =
  | { ok: true; evidence: NormalizedTransferEvidence; amountBaseUnits: string; solidifiedBlockHeight: number }
  | { ok: false; reason: string };

async function providerPost(baseUrl: string, path: string, apiKey: string, body: unknown, fetcher: typeof fetch): Promise<any> {
  const response = await fetcher(baseUrl + path, {
    method: "POST",
    headers: { "TRON-PRO-API-KEY": apiKey, "Content-Type": "application/json", "Accept": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(12_000),
  });
  if (!response.ok) throw new Error("provider_http_error");
  const result = await response.json();
  if (!result || typeof result !== "object" || Array.isArray(result) || result.Error) throw new Error("provider_invalid_response");
  return result;
}

export async function verifyWithdrawalTransfer(
  expected: WithdrawalExpectation,
  config: { baseUrl: string; apiKey: string; fetcher?: typeof fetch },
): Promise<WithdrawalVerification> {
  const hash = expected.transactionId.trim().toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(hash)) return { ok: false, reason: "invalid_transaction_hash" };
  const amountBaseUnits = withdrawalAmountToBaseUnits(expected.amount);
  if (!amountBaseUnits) return { ok: false, reason: "invalid_or_unsupported_usdt_precision" };
  if (!expected.recipientAddress || !expected.tokenContractAddress ||
      !Number.isSafeInteger(expected.minimumConfirmations) || expected.minimumConfirmations < 1) {
    return { ok: false, reason: "invalid_verification_configuration" };
  }
  const fetcher = config.fetcher ?? fetch;
  const base = config.baseUrl.replace(/\/+$/, "");
  const [receipt, solidifiedHead] = await Promise.all([
    providerPost(base, "/walletsolidity/gettransactioninfobyid", config.apiKey, { value: hash }, fetcher),
    providerPost(base, "/walletsolidity/getnowblock", config.apiKey, {}, fetcher),
  ]);
  if (Object.keys(receipt).length === 0) return { ok: false, reason: "solidified_receipt_not_found" };
  const solidifiedHeight = solidifiedHead.block_header?.raw_data?.number;
  if (!Number.isSafeInteger(solidifiedHeight) || solidifiedHeight < 0) throw new Error("invalid_solidified_head");
  const transfers = await normalizeSolidifiedTransferLogs(
    receipt, hash, expected.tokenContractAddress, expected.minimumConfirmations, solidifiedHeight,
  );
  const valid = transfers.filter((evidence) => validateUsdtTransfer(evidence, {
    transactionId: hash,
    contractAddress: expected.tokenContractAddress,
    recipientAddress: expected.recipientAddress,
    minimumConfirmations: expected.minimumConfirmations,
    expectedAmountBaseUnits: amountBaseUnits,
  }).ok);
  if (valid.length === 0) return { ok: false, reason: "no_exact_successful_transfer_to_requested_recipient" };
  if (valid.length !== 1) return { ok: false, reason: "ambiguous_matching_transfer_events" };
  return { ok: true, evidence: valid[0], amountBaseUnits, solidifiedBlockHeight: solidifiedHeight };
}
