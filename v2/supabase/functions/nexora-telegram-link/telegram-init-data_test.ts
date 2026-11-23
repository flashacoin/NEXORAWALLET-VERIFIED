import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { verifyTelegramInitData } from "./telegram-init-data.ts";

const encoder = new TextEncoder();
async function sign(keyBytes: Uint8Array, message: string): Promise<Uint8Array> {
  const keyData = new ArrayBuffer(keyBytes.byteLength);
  new Uint8Array(keyData).set(keyBytes);
  const key = await crypto.subtle.importKey("raw", keyData, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(message)));
}
function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}
async function fixture(botToken: string, authDate: number): Promise<string> {
  const params = new URLSearchParams();
  params.set("auth_date", String(authDate));
  params.set("query_id", "AAE-test-query");
  params.set("user", JSON.stringify({ id: 123456789, first_name: "Nexora", username: "nexora_test" }));
  const dataCheck = Array.from(params.entries()).sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => k + "=" + v).join("\n");
  // Telegram's documented derivation: HMAC_SHA256(key=bot_token, message="WebAppData").
  const secretKey = await sign(encoder.encode(botToken), "WebAppData");
  params.set("hash", hex(await sign(secretKey, dataCheck)));
  return params.toString();
}

Deno.test("accepts correctly signed, fresh Telegram Mini App initData", async () => {
  const now = 1_800_000_000;
  const raw = await fixture("123456:TEST_BOT_TOKEN", now - 30);
  const user = await verifyTelegramInitData(raw, "123456:TEST_BOT_TOKEN", now);
  assertEquals(user.id, 123456789);
  assertEquals(user.username, "nexora_test");
});

Deno.test("rejects tampered Telegram initData", async () => {
  const now = 1_800_000_000;
  const raw = await fixture("123456:TEST_BOT_TOKEN", now - 30);
  const tampered = raw.replace("nexora_test", "attacker");
  await assertRejects(() => verifyTelegramInitData(tampered, "123456:TEST_BOT_TOKEN", now), Error, "invalid_telegram_signature");
});

Deno.test("rejects expired Telegram initData", async () => {
  const now = 1_800_000_000;
  const raw = await fixture("123456:TEST_BOT_TOKEN", now - 86401);
  await assertRejects(() => verifyTelegramInitData(raw, "123456:TEST_BOT_TOKEN", now), Error, "telegram_init_data_expired");
});

Deno.test("rejects malformed or oversized Telegram initData", async () => {
  await assertRejects(() => verifyTelegramInitData("hash=bad", "token", 1_800_000_000));
  await assertRejects(() => verifyTelegramInitData("x".repeat(8193), "token", 1_800_000_000));
});
