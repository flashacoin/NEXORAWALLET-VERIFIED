// Pure, fail-closed validation for normalized TRON USDT Transfer evidence.
// This module performs no network calls, database writes, or wallet credits.
// Callers must normalize provider responses and independently establish finality.
export type NormalizedTransferEvidence = {
  transactionId: string;
  blockNumber: number;
  contractAddress: string;
  eventName: string;
  eventIndex: number;
  from: string;
  to: string;
  value: string; // unsigned integer token base units; never a JS number
  receiptResult: string;
  confirmations: number;
};

export type TransferExpectation = {
  transactionId: string;
  contractAddress: string; // trusted server configuration
  recipientAddress: string; // trusted server configuration
  minimumConfirmations: number;
  expectedAmountBaseUnits?: string;
};

export type TransferValidation =
  | { ok: true; evidence: NormalizedTransferEvidence }
  | { ok: false; reason: string };

const HASH = /^[a-f0-9]{64}$/i;
const UINT = /^(0|[1-9][0-9]*)$/;

export function validateUsdtTransfer(
  evidence: NormalizedTransferEvidence,
  expected: TransferExpectation,
): TransferValidation {
  if (!HASH.test(expected.transactionId)) return { ok: false, reason: "invalid_expected_transaction_id" };
  if (!HASH.test(evidence.transactionId) || evidence.transactionId.toLowerCase() !== expected.transactionId.toLowerCase()) {
    return { ok: false, reason: "transaction_id_mismatch" };
  }
  if (!expected.contractAddress || evidence.contractAddress !== expected.contractAddress) {
    return { ok: false, reason: "token_contract_mismatch" };
  }
  if (evidence.eventName !== "Transfer") return { ok: false, reason: "not_transfer_event" };
  if (!Number.isSafeInteger(evidence.eventIndex) || evidence.eventIndex < 0) return { ok: false, reason: "invalid_event_index" };
  if (!evidence.from || !evidence.to || evidence.to !== expected.recipientAddress) {
    return { ok: false, reason: "recipient_mismatch" };
  }
  if (!UINT.test(evidence.value) || evidence.value === "0") return { ok: false, reason: "invalid_token_amount" };
  if (expected.expectedAmountBaseUnits !== undefined) {
    if (!UINT.test(expected.expectedAmountBaseUnits) || evidence.value !== expected.expectedAmountBaseUnits) {
      return { ok: false, reason: "amount_mismatch" };
    }
  }
  if (evidence.receiptResult !== "SUCCESS") return { ok: false, reason: "transaction_not_successful" };
  if (!Number.isSafeInteger(evidence.confirmations) || evidence.confirmations < 0 ||
    !Number.isSafeInteger(expected.minimumConfirmations) || expected.minimumConfirmations < 1 ||
    evidence.confirmations < expected.minimumConfirmations) {
    return { ok: false, reason: "insufficient_confirmations" };
  }
  return { ok: true, evidence: { ...evidence } };
}

// Convert a human decimal amount to token base units without floating-point arithmetic.
export function usdtAmountToBaseUnits(amount: string): string | null {
  if (!/^(0|[1-9][0-9]*)(\.[0-9]{1,6})?$/.test(amount)) return null;
  const [whole, fraction = ""] = amount.split(".");
  const rawUnits = whole + fraction.padEnd(6, "0");
  const units = rawUnits.replace(/^0+(?=[0-9])/, "");
  if (!UINT.test(units) || units === "0") return null;
  return units;
}
