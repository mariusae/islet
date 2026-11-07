// Minimal APNs client for Live Activity pushes, using token (JWT) authentication.
// Workers' fetch() negotiates HTTP/2 with api.push.apple.com, which APNs requires.
import type { ActivityState } from "./alerts";

export type ApnsEnvironment = "sandbox" | "production";

export interface ApnsConfig {
  teamId: string;
  keyId: string;
  /** PEM contents of the AuthKey_XXXXXXXXXX.p8 file. */
  privateKey: string;
  /** The app's bundle identifier. */
  topic: string;
}

export interface ApnsResult {
  ok: boolean;
  status: number;
  reason?: string;
  /** The token is no longer valid (activity ended, app deleted, wrong environment); stop using it. */
  tokenInvalid: boolean;
}

const HOSTS: Record<ApnsEnvironment, string> = {
  sandbox: "https://api.sandbox.push.apple.com",
  production: "https://api.push.apple.com",
};

// Apple wants provider tokens reused for 20–60 minutes, not minted per request.
let cachedJwt: { token: string; issuedAt: number; keyId: string } | undefined;

export async function providerToken(config: ApnsConfig, now = Math.floor(Date.now() / 1000)): Promise<string> {
  if (cachedJwt && cachedJwt.keyId === config.keyId && now - cachedJwt.issuedAt < 45 * 60) return cachedJwt.token;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(config.privateKey),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = b64url(JSON.stringify({ alg: "ES256", kid: config.keyId }));
  const claims = b64url(JSON.stringify({ iss: config.teamId, iat: now }));
  const input = `${header}.${claims}`;
  // WebCrypto produces the raw r||s (IEEE P1363) signature that JWS ES256 expects.
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  const token = `${input}.${b64url(new Uint8Array(sig))}`;
  cachedJwt = { token, issuedAt: now, keyId: config.keyId };
  return token;
}

/** `sound: false` shows the activity without lighting the screen or buzzing (e.g. a quiet restart). */
export interface LiveActivityAlert {
  title: string;
  body: string;
  sound?: boolean;
}

export type LiveActivityEvent =
  | { event: "start"; state: ActivityState; alert: LiveActivityAlert }
  | { event: "update"; state: ActivityState; alert?: LiveActivityAlert }
  | { event: "end"; state: ActivityState };

export function payload(e: LiveActivityEvent, now: number, staleAfter: number): Record<string, unknown> {
  const aps: Record<string, unknown> = {
    timestamp: now,
    event: e.event,
    "content-state": e.state,
  };
  if (e.event !== "end") {
    aps["stale-date"] = e.state.timestamp + staleAfter;
    aps["relevance-score"] = e.state.alerts.length > 0 ? 100 : 50;
  } else {
    aps["dismissal-date"] = now;
  }
  if (e.event === "start") {
    aps["attributes-type"] = "GlucoseActivityAttributes";
    aps.attributes = {};
    // Ask iOS to mint an update token for the new activity and hand it to the app.
    aps["input-push-token"] = 1;
  }
  if (e.event !== "end" && e.alert) {
    aps.alert = { title: e.alert.title, body: e.alert.body, ...(e.alert.sound === false ? {} : { sound: "default" }) };
  }
  return { aps };
}

export async function sendLiveActivity(
  config: ApnsConfig,
  environment: ApnsEnvironment,
  deviceToken: string,
  body: Record<string, unknown>,
  urgent: boolean,
): Promise<ApnsResult> {
  const jwt = await providerToken(config);
  const res = await fetch(`${HOSTS[environment]}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": `${config.topic}.push-type.liveactivity`,
      "apns-push-type": "liveactivity",
      "apns-priority": urgent ? "10" : "5",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 10 * 60),
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
  if (res.ok) return { ok: true, status: res.status, tokenInvalid: false };
  let reason: string | undefined;
  try {
    reason = ((await res.json()) as { reason?: string }).reason;
  } catch {
    // APNs always sends a JSON reason on failure, but don't let a surprise break polling.
  }
  if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") cachedJwt = undefined;
  const tokenInvalid = res.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered";
  return { ok: false, status: res.status, reason, tokenInvalid };
}

function pemToDer(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return bytes.buffer;
}

function b64url(input: string | Uint8Array): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
