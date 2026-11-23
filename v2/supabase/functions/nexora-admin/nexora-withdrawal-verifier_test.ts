import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { verifyWithdrawalTransfer, withdrawalAmountToBaseUnits } from "./nexora-withdrawal-verifier.ts";
import type { NormalizedTransferEvidence } from "../nexora-deposit-verify-preview/tron-usdt-transfer.ts";

const base: NormalizedTransferEvidence = {
  transactionId: "a".repeat(64), blockNumber: 100, contractAddress: "TContract",
  eventName: "Transfer", eventIndex: 0, from: "TSender", to: "TRecipient",
  value: "100000000", receiptResult: "SUCCESS", confirmations: 20,
};

Deno.test("withdrawal amount conversion accepts database trailing zero scale", () => {
  assertEquals(withdrawalAmountToBaseUnits("100.0000000000"), "100000000");
  assertEquals(withdrawalAmountToBaseUnits("0.000001"), "1");
});
Deno.test("withdrawal amount conversion rejects precision beyond six non-zero decimals", () => {
  assertEquals(withdrawalAmountToBaseUnits("1.0000001"), null);
});
Deno.test("TRON withdrawal verifier helper rejects invalid precision before provider calls", async () => {
  let called = false;
  const result = await verifyWithdrawalTransfer({
    transactionId: "a".repeat(64), tokenContractAddress: "TContract",
    recipientAddress: "TRecipient", amount: "1.0000001", minimumConfirmations: 10,
  }, { baseUrl: "https://example.invalid", apiKey: "test", fetcher: async () => {
    called = true; throw new Error("should not call provider");
  } });
  assertEquals(result, { ok: false, reason: "invalid_or_unsupported_usdt_precision" });
  assertEquals(called, false);
});

Deno.test("TRON withdrawal verifier fails closed on malformed hash", async () => {
  const result = await verifyWithdrawalTransfer({
    transactionId: "not-a-hash", tokenContractAddress: "TContract",
    recipientAddress: "TRecipient", amount: "100", minimumConfirmations: 10,
  }, { baseUrl: "https://example.invalid", apiKey: "test", fetcher: async () => {
    throw new Error("should not call provider");
  } });
  assertEquals(result, { ok: false, reason: "invalid_transaction_hash" });
});
