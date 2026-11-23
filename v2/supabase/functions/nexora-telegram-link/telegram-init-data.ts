const encoder = new TextEncoder();

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
}

function constantTimeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return difference === 0;
}

async function hmac(keyBytes: Uint8Array, message: string): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    "raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(message)));
}

export type TelegramWebAppUser = {
  id: number;
  username?: string;
  first_name?: string;
  last_name?: string;
};

export function parseTelegramInitDataUser(raw: string): { user: TelegramWebAppUser; authDate: number } {
  const params = new URLSearchParams(raw);
  const rawUser = params.get("user");
  const authDate = Number(params.get("auth_date"));
  if (!rawUser || !Number.isSafeInteger(authDate) || authDate <= 0) {
    throw new Error("invalid_telegram_init_data");
  }
  let user: TelegramWebAppUser;
  try { user = JSON.parse(rawUser); } catch { throw new Error("invalid_telegram_user"); }
  if (!user || !Number.isSafeInteger(user.id) || user.id <= 0) {
    throw new Error("invalid_telegram_user");
  }
  return { user, authDate };
}

export async function verifyTelegramInitData(
  raw: string,
  botToken: string,
  nowSeconds = Math.floor(Date.now() / 1000),
  maxAgeSeconds = 86400,
): Promise<TelegramWebAppUser> {
  if (!raw || raw.length > 8192 || !botToken) throw new Error("invalid_telegram_init_data");
  const params = new URLSearchParams(raw);
  const receivedHash = (params.get("hash") ?? "").toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(receivedHash)) throw new Error("invalid_telegram_signature");
  params.delete("hash");

  const { user, authDate } = parseTelegramInitDataUser(raw);
  if (authDate > nowSeconds + 60 || nowSeconds - authDate > maxAgeSeconds) {
    throw new Error("telegram_init_data_expired");
  }

  const dataCheckString = Array.from(params.entries())
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => key + "=" + value)
    .join("\n");
  const secretKey = await hmac(encoder.encode("WebAppData"), botToken);
  const calculatedHash = toHex(await hmac(secretKey, dataCheckString));
  if (!constantTimeEqual(calculatedHash, receivedHash)) {
    throw new Error("invalid_telegram_signature");
  }
  return user;
}
