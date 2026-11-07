// AES-GCM encryption for Dexcom credentials at rest in Durable Object storage.

async function key(base64Key: string): Promise<CryptoKey> {
  const raw = Uint8Array.from(atob(base64Key), (c) => c.charCodeAt(0));
  if (raw.length !== 32) throw new Error("CREDENTIALS_KEY must be 32 bytes, base64-encoded (openssl rand -base64 32)");
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

export async function seal(value: unknown, base64Key: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const data = new TextEncoder().encode(JSON.stringify(value));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await key(base64Key), data));
  return `${toB64(iv)}.${toB64(ct)}`;
}

export async function open<T>(sealed: string, base64Key: string): Promise<T> {
  const [iv, ct] = sealed.split(".");
  if (!iv || !ct) throw new Error("Malformed sealed value");
  const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: fromB64(iv) }, await key(base64Key), fromB64(ct));
  return JSON.parse(new TextDecoder().decode(pt)) as T;
}

function toB64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function fromB64(s: string): Uint8Array {
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}
