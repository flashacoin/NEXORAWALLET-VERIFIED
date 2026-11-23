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

Deno.test("rejects invalid minimum confirmation policy", () => {
  assertEquals(reasonOf(validateUsdtTransfer(evidence, { ...expected, minimumConfirmations: 0 })), "insufficient_confirmations");
  assertEquals(reasonOf(validateUsdtTransfer(evidence, { ...expected, minimumConfirmations: -1 })), "insufficient_confirmations");
});
Deno.test("rejects malformed event index and negative confirmations", () => {
  assertEquals(reasonOf(validateUsdtTransfer({ ...evidence, eventIndex: 0.5 }, expected)), "invalid_event_index");
  assertEquals(reasonOf(validateUsdtTransfer({ ...evidence, confirmations: -1 }, expected)), "insufficient_confirmations");
});
Deno.test("rejects missing sender or recipient", () => {
  assertEquals(reasonOf(validateUsdtTransfer({ ...evidence, from: "" }, expected)), "recipient_mismatch");
  assertEquals(reasonOf(validateUsdtTransfer({ ...evidence, to: "" }, expected)), "recipient_mismatch");
});
Deno.test("rejects malformed expected amount", () => {
  assertEquals(reasonOf(validateUsdtTransfer(evidence, { ...expected, expectedAmountBaseUnits: "1.2" })), "amount_mismatch");
});
Deno.test("supports large integer base-unit amounts without floating point", () => {
  const large = "999999999999999999999999999";
  assertEquals(validateUsdtTransfer({ ...evidence, value: large }, { ...expected, expectedAmountBaseUnits: large }).ok, true);
  assertEquals(usdtAmountToBaseUnits("999999999999999999.999999"), "999999999999999999999999");
});

import { normalizeSolidifiedTransferLogs, tronAddressToHex, tronHexToAddress } from "./tron-provider-normalizer.ts";

const tetherAddress = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t";
const tetherHex = "41a614f803b6fd780986a42c78ec9c7f77e6ded13c";
const topicFor = (hex: string) => "0".repeat(24) + hex.slice(2);
const receiptFixture = (overrides: Record<string, unknown> = {}) => ({
  id: hash,
  blockNumber: 100,
  receipt: { result: "SUCCESS" },
  log: [{
    address: tetherHex,
    topics: [
      "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
      "0x" + topicFor(tetherHex),
      "0x" + topicFor(tetherHex),
    ],
    data: "0".repeat(63) + "1",
  }],
  ...overrides,
});

Deno.test("converts the official TRON USDT address with Base58Check", async () => {
  assertEquals(await tronAddressToHex(tetherAddress), tetherHex);
  assertEquals(await tronHexToAddress(tetherHex), tetherAddress);
});
Deno.test("normalizes solidified receipt Transfer logs for validator input", async () => {
  const normalized = await normalizeSolidifiedTransferLogs(
    receiptFixture(), hash, tetherAddress, 10, 120,
  );
  assertEquals(normalized.length, 1);
  assertEquals(normalized[0].transactionId, hash);
  assertEquals(normalized[0].contractAddress, tetherAddress);
  assertEquals(normalized[0].eventName, "Transfer");
  assertEquals(normalized[0].eventIndex, 0);
  assertEquals(normalized[0].from, tetherAddress);
  assertEquals(normalized[0].to, tetherAddress);
  assertEquals(normalized[0].value, "1");
  assertEquals(normalized[0].confirmations, 21);
  assertEquals(validateUsdtTransfer(normalized[0], {
    transactionId: hash, contractAddress: tetherAddress,
    recipientAddress: tetherAddress, minimumConfirmations: 10,
  }).ok, true);
});
Deno.test("rejects a receipt for another transaction", async () => {
  let thrown = false;
  try {
    await normalizeSolidifiedTransferLogs(receiptFixture({ id: "b".repeat(64) }), hash, tetherAddress, 1, 120);
  } catch { thrown = true; }
  assertEquals(thrown, true);
});
Deno.test("rejects failed or not-yet-solidified receipts", async () => {
  for (const fixture of [
    receiptFixture({ receipt: { result: "FAILED" } }),
    receiptFixture({ blockNumber: 121 }),
  ]) {
    let thrown = false;
    try { await normalizeSolidifiedTransferLogs(fixture, hash, tetherAddress, 1, 120); }
    catch { thrown = true; }
    assertEquals(thrown, true);
  }
});
Deno.test("ignores non-Transfer and wrong-contract logs", async () => {
  const fixture = receiptFixture({
    log: [
      { address: tetherHex, topics: ["0x" + "0".repeat(64)], data: "0".repeat(64) },
      { address: "41" + "b".repeat(40), topics: [
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        "0x" + topicFor(tetherHex), "0x" + topicFor(tetherHex),
      ], data: "0".repeat(63) + "1" },
    ],
  });
  assertEquals((await normalizeSolidifiedTransferLogs(fixture, hash, tetherAddress, 1, 120)).length, 0);
});
Deno.test("rejects malformed transfer topics and data", async () => {
  const fixture = receiptFixture({
    log: [{
      address: tetherHex,
      topics: ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef", "bad", "bad"],
      data: "1",
    }],
  });
  assertEquals((await normalizeSolidifiedTransferLogs(fixture, hash, tetherAddress, 1, 120)).length, 0);
});
Deno.test("rejects invalid configured Base58Check addresses", async () => {
  let thrown = false;
  try { await tronAddressToHex("TInvalidAddress"); } catch { thrown = true; }
  assertEquals(thrown, true);
});
