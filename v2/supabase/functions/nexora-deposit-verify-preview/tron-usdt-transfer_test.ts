import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { usdtAmountToBaseUnits, validateUsdtTransfer, type NormalizedTransferEvidence, type TransferExpectation } from "./tron-usdt-transfer.ts";

const hash = "a".repeat(64);
const evidence: NormalizedTransferEvidence = {
  transactionId: hash, contractAddress: "TOfficialContractConfiguredByServer",
  eventName: "Transfer", eventIndex: 0, from: "TSender",
  to: "TDepositAddressConfiguredByServer", value: "1234567",
  receiptResult: "SUCCESS", confirmations: 20,
};
function reasonOf(result: ReturnType<typeof validateUsdtTransfer>): string {
  return result.ok ? "ok" : result.reason;
}

const expected: TransferExpectation = {
  transactionId: hash, contractAddress: evidence.contractAddress,
  recipientAddress: evidence.to, minimumConfirmations: 19,
  expectedAmountBaseUnits: "1234567",
};

Deno.test("accepts exact configured successful transfer evidence", () => {
  assertEquals(validateUsdtTransfer(evidence, expected).ok, true);
});
Deno.test("rejects a different transaction ID", () => {
  assertEquals(validateUsdtTransfer({ ...evidence, transactionId: "b".repeat(64) }, expected), { ok: false, reason: "transaction_id_mismatch" });
});
Deno.test("rejects a different token contract", () => {
  assertEquals(reasonOf(validateUsdtTransfer({ ...evidence, contractAddress: "TWrongContract" }, expected)), "token_contract_mismatch");
});
Deno.test("rejects a different recipient", () => {
  assertEquals(reasonOf(validateUsdtTransfer({ ...evidence, to: "TAttacker" }, expected)), "recipient_mismatch");
});
Deno.test("rejects non-Transfer event", () => {
  assertEquals(reasonOf(validateUsdtTransfer({ ...evidence, eventName: "Approval" }, expected)), "not_transfer_event");
});
Deno.test("rejects unsuccessful transaction", () => {
  assertEquals(reasonOf(validateUsdtTransfer({ ...evidence, receiptResult: "FAILED" }, expected)), "transaction_not_successful");
});
Deno.test("rejects insufficient confirmations", () => {
  assertEquals(reasonOf(validateUsdtTransfer({ ...evidence, confirmations: 2 }, expected)), "insufficient_confirmations");
});
Deno.test("rejects zero, malformed, and mismatched amounts", () => {
  assertEquals(reasonOf(validateUsdtTransfer({ ...evidence, value: "0" }, expected)), "invalid_token_amount");
  assertEquals(reasonOf(validateUsdtTransfer({ ...evidence, value: "1e6" }, expected)), "invalid_token_amount");
  assertEquals(reasonOf(validateUsdtTransfer({ ...evidence, value: "1234568" }, expected)), "amount_mismatch");
});
Deno.test("rejects unsafe event indexes", () => {
  assertEquals(reasonOf(validateUsdtTransfer({ ...evidence, eventIndex: -1 }, expected)), "invalid_event_index");
});
Deno.test("converts decimal USDT to integer base units exactly", () => {
  assertEquals(usdtAmountToBaseUnits("1"), "1000000");
  assertEquals(usdtAmountToBaseUnits("1.234567"), "1234567");
  assertEquals(usdtAmountToBaseUnits("0.000001"), "1");
  assertEquals(usdtAmountToBaseUnits("1.000000"), "1000000");
  assertEquals(usdtAmountToBaseUnits("1.0000001"), null);
  assertEquals(usdtAmountToBaseUnits("0"), null);
  assertEquals(usdtAmountToBaseUnits("-1"), null);
});
