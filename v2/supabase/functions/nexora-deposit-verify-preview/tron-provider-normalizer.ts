// Normalize TRON SolidityNode receipts into the validator's trusted input shape.
// This module is deliberately pure apart from checksum hashing; it performs no network
// requests, database writes, or wallet credits.
import type { NormalizedTransferEvidence } from "./tron-usdt-transfer.ts";

const BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
const TRANSFER_TOPIC = "ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
const HEX = /^[0-9a-f]+$/i;

async function sha256(bytes: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a); out.set(b, a.length);
  return out;
}

function hexBytes(hex: string): Uint8Array {
  if (!HEX.test(hex) || hex.length % 2 !== 0) throw new Error("invalid_hex");
  return Uint8Array.from(hex.match(/.{2}/g)!, (part) => Number.parseInt(part, 16));
}

function bytesHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function tronHexToAddress(input: string): Promise<string> {
  let hex = input.replace(/^0x/i, "").toLowerCase();
  if (/^[0-9a-f]{40}$/.test(hex)) hex = "41" + hex;
  if (!/^41[0-9a-f]{40}$/.test(hex)) throw new Error("invalid_tron_hex_address");
  const payload = hexBytes(hex);
  const checksum = (await sha256(await sha256(payload))).slice(0, 4);
  const bytes = concat(payload, checksum);
  let value = BigInt("0x" + bytesHex(bytes));
  let encoded = "";
  while (value > 0n) {
    const remainder = Number(value % 58n);
    encoded = BASE58[remainder] + encoded;
    value /= 58n;
  }
  for (const byte of bytes) {
    if (byte !== 0) break;
    encoded = "1" + encoded;
  }
  return encoded;
}

export async function tronAddressToHex(address: string): Promise<string> {
  if (typeof address !== "string" || !address || address.length > 64) throw new Error("invalid_tron_address");
  let value = 0n;
  for (const char of address) {
    const digit = BASE58.indexOf(char);
    if (digit < 0) throw new Error("invalid_tron_address");
    value = value * 58n + BigInt(digit);
  }
  let hex = value.toString(16);
  if (hex.length % 2) hex = "0" + hex;
  let decoded = hexBytes(hex);
  let leading = 0;
  while (leading < address.length && address[leading] === "1") leading++;
  if (leading) decoded = concat(new Uint8Array(leading), decoded);
  if (decoded.length !== 25) throw new Error("invalid_tron_address_length");
  const payload = decoded.slice(0, 21);
  const checksum = decoded.slice(21);
  const expected = (await sha256(await sha256(payload))).slice(0, 4);
  if (bytesHex(checksum) !== bytesHex(expected) || payload[0] !== 0x41) {
    throw new Error("invalid_tron_address_checksum");
  }
  return bytesHex(payload);
}

function topicAddress(topic: unknown): string {
  if (typeof topic !== "string") throw new Error("invalid_event_topic");
  const normalized = topic.replace(/^0x/i, "");
  if (!/^[0-9a-f]{64}$/i.test(normalized) || !/^0{24}[0-9a-f]{40}$/i.test(normalized)) {
    throw new Error("invalid_event_address_topic");
  }
  return "41" + normalized.slice(24);
}

export async function normalizeSolidifiedTransferLogs(
  receipt: unknown,
  transactionId: string,
  configuredContract: string,
  minimumConfirmations: number,
  solidifiedBlockHeight: number,
): Promise<NormalizedTransferEvidence[]> {
  if (!/^[a-f0-9]{64}$/i.test(transactionId)) throw new Error("invalid_transaction_id");
  if (!Number.isSafeInteger(minimumConfirmations) || minimumConfirmations < 1 ||
      !Number.isSafeInteger(solidifiedBlockHeight) || solidifiedBlockHeight < 0) {
    throw new Error("invalid_finality_policy");
  }
  const expectedContractHex = await tronAddressToHex(configuredContract);
  if (!receipt || typeof receipt !== "object" || Array.isArray(receipt)) throw new Error("invalid_receipt");
  const data = receipt as Record<string, unknown>;
  if (typeof data.id !== "string" || data.id.toLowerCase() !== transactionId.toLowerCase()) {
    throw new Error("receipt_transaction_id_mismatch");
  }
  if (!Number.isSafeInteger(data.blockNumber) || (data.blockNumber as number) < 0) {
    throw new Error("invalid_receipt_block");
  }
  const blockNumber = data.blockNumber as number;
  if (blockNumber > solidifiedBlockHeight) throw new Error("receipt_not_solidified");
  const receiptObject = data.receipt && typeof data.receipt === "object"
    ? data.receipt as Record<string, unknown> : {};
  const receiptResult = receiptObject.result ?? data.result;
  if (receiptResult !== "SUCCESS") throw new Error("transaction_not_successful");
  if (!Array.isArray(data.log)) throw new Error("receipt_logs_missing");

  const confirmations = solidifiedBlockHeight - blockNumber + 1;
  const evidence: NormalizedTransferEvidence[] = [];
  for (let index = 0; index < data.log.length; index++) {
    const raw = data.log[index];
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
    const log = raw as Record<string, unknown>;
    if (typeof log.address !== "string" || !Array.isArray(log.topics) ||
        typeof log.data !== "string") continue;
    const topics = log.topics;
    if (typeof topics[0] !== "string" ||
        topics[0].replace(/^0x/i, "").toLowerCase() !== TRANSFER_TOPIC) continue;
    if (topics.length !== 3 || !/^[0-9a-f]{64}$/i.test(log.data.replace(/^0x/i, ""))) continue;
    const contractHex = log.address.replace(/^0x/i, "").toLowerCase();
    const canonicalContractHex = /^[0-9a-f]{40}$/i.test(contractHex)
      ? "41" + contractHex
      : contractHex;
    if (canonicalContractHex !== expectedContractHex) continue;
    const fromHex = topicAddress(topics[1]);
    const toHex = topicAddress(topics[2]);
    const amount = BigInt("0x" + log.data.replace(/^0x/i, "")).toString(10);
    evidence.push({
      transactionId: data.id,
      contractAddress: await tronHexToAddress(canonicalContractHex),
      eventName: "Transfer",
      eventIndex: index,
      from: await tronHexToAddress(fromHex),
      to: await tronHexToAddress(toHex),
      value: amount,
      receiptResult: "SUCCESS",
      confirmations,
    });
  }
  return evidence;
}
