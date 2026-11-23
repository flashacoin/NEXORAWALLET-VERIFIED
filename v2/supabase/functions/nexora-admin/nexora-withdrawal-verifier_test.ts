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


import { tronAddressToHex } from "../nexora-deposit-verify-preview/tron-provider-normalizer.ts";

const tetherAddress = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t";
const tetherHex = "41a614f803b6fd780986a42c78ec9c7f77e6ded13c";
const transactionId = "c".repeat(64);
const transferTopic = "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const topicForAddress = (hex: string) => "0".repeat(24) + hex.slice(2);
const toHex32 = (value: bigint) => value.toString(16).padStart(64, "0");

function mockedProvider(receipt: Record<string, unknown>, solidifiedHeight = 120) {
  const calls: string[] = [];
  const fetcher: typeof fetch = async (input, init) => {
    const url = String(input);
    calls.push(url);
    const payload = url.endsWith("/walletsolidity/getnowblock")
      ? { block_header: { raw_data: { number: solidifiedHeight } } }
      : receipt;
    return new Response(JSON.stringify(payload), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  };
  return { fetcher, calls };
}

function providerReceipt(recipientHex = tetherHex, amountBaseUnits = 10_000_000n) {
  return {
    id: transactionId,
    blockNumber: 100,
    receipt: { result: "SUCCESS" },
    log: [{
      address: tetherHex,
      topics: [
        "0x" + transferTopic,
        "0x" + topicForAddress(tetherHex),
        "0x" + topicForAddress(recipientHex),
      ],
      data: "0x" + toHex32(amountBaseUnits),
    }],
  };
}

Deno.test("withdrawal verifier accepts one exact solidified USDT payout", async () => {
  const mock = mockedProvider(providerReceipt());
  const result = await verifyWithdrawalTransfer({
    transactionId,
    tokenContractAddress: tetherAddress,
    recipientAddress: tetherAddress,
    amount: "10.000000",
    minimumConfirmations: 20,
  }, { baseUrl: "https://tron.example", apiKey: "test-key", fetcher: mock.fetcher });
  assertEquals(result.ok, true);
  if (result.ok) {
    assertEquals(result.amountBaseUnits, "10000000");
    assertEquals(result.evidence.receiptResult, "SUCCESS");
    assertEquals(result.evidence.confirmations, 21);
    assertEquals(result.evidence.to, tetherAddress);
    assertEquals(result.solidifiedBlockHeight, 120);
  }
  assertEquals(mock.calls.length, 2);
});

Deno.test("withdrawal verifier rejects a payout amount that differs from the request", async () => {
  const mock = mockedProvider(providerReceipt(tetherHex, 9_999_999n));
  const result = await verifyWithdrawalTransfer({
    transactionId, tokenContractAddress: tetherAddress, recipientAddress: tetherAddress,
    amount: "10", minimumConfirmations: 10,
  }, { baseUrl: "https://tron.example", apiKey: "test-key", fetcher: mock.fetcher });
  assertEquals(result, { ok: false, reason: "no_exact_successful_transfer_to_requested_recipient" });
});

Deno.test("withdrawal verifier rejects a transfer to another recipient", async () => {
  const otherHex = await tronAddressToHex("TJRabPrwbZy45sbavfcjinPJC18kjpRTv8");
  const mock = mockedProvider(providerReceipt(otherHex));
  const result = await verifyWithdrawalTransfer({
    transactionId, tokenContractAddress: tetherAddress, recipientAddress: tetherAddress,
    amount: "10", minimumConfirmations: 10,
  }, { baseUrl: "https://tron.example", apiKey: "test-key", fetcher: mock.fetcher });
  assertEquals(result, { ok: false, reason: "no_exact_successful_transfer_to_requested_recipient" });
});

Deno.test("withdrawal verifier rejects a payout below the configured confirmation threshold", async () => {
  const mock = mockedProvider(providerReceipt(), 105);
  const result = await verifyWithdrawalTransfer({
    transactionId, tokenContractAddress: tetherAddress, recipientAddress: tetherAddress,
    amount: "10", minimumConfirmations: 10,
  }, { baseUrl: "https://tron.example", apiKey: "test-key", fetcher: mock.fetcher });
  assertEquals(result, { ok: false, reason: "no_exact_successful_transfer_to_requested_recipient" });
});

Deno.test("withdrawal verifier fails closed when the solidified receipt is missing", async () => {
  const mock = mockedProvider({});
  const result = await verifyWithdrawalTransfer({
    transactionId, tokenContractAddress: tetherAddress, recipientAddress: tetherAddress,
    amount: "10", minimumConfirmations: 10,
  }, { baseUrl: "https://tron.example", apiKey: "test-key", fetcher: mock.fetcher });
  assertEquals(result, { ok: false, reason: "solidified_receipt_not_found" });
});

Deno.test("withdrawal verifier propagates provider failures instead of accepting unknown state", async () => {
  const fetcher: typeof fetch = async () => new Response("unavailable", { status: 503 });
  let rejected = false;
  try {
    await verifyWithdrawalTransfer({
      transactionId, tokenContractAddress: tetherAddress, recipientAddress: tetherAddress,
      amount: "10", minimumConfirmations: 10,
    }, { baseUrl: "https://tron.example", apiKey: "test-key", fetcher });
  } catch { rejected = true; }
  assertEquals(rejected, true);
});
