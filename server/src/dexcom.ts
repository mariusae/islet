// Dexcom Share client. Mirror of IsletKit's DexcomShareClient.swift.
import type { Reading, Trend } from "./alerts";

export type Region = "us" | "outsideUS" | "japan";

const BASE_URLS: Record<Region, string> = {
  us: "https://share2.dexcom.com/ShareWebServices/Services/",
  outsideUS: "https://shareous1.dexcom.com/ShareWebServices/Services/",
  japan: "https://share.dexcom.jp/ShareWebServices/Services/",
};

const APPLICATION_IDS: Record<Region, string> = {
  us: "d89443d2-327c-4a6f-89e5-496bbb0317db",
  outsideUS: "d89443d2-327c-4a6f-89e5-496bbb0317db",
  japan: "d8665ade-9673-4e27-9ff6-92db4ce13d13",
};

const NULL_UUID = "00000000-0000-0000-0000-000000000000";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const TRENDS: Trend[] = [
  "None", "DoubleUp", "SingleUp", "FortyFiveUp", "Flat",
  "FortyFiveDown", "SingleDown", "DoubleDown", "NotComputable", "RateOutOfRange",
];

export interface Credentials {
  username: string;
  password: string;
  region: Region;
}

export type DexcomErrorKind = "invalidCredentials" | "accountNotFound" | "tooManyAttempts" | "sessionInvalid" | "server";

export class DexcomError extends Error {
  constructor(readonly kind: DexcomErrorKind, message: string) {
    super(message);
  }

  /** Errors where retrying with the same credentials is pointless (and risks locking the account). */
  get isFatal(): boolean {
    return this.kind === "invalidCredentials" || this.kind === "accountNotFound" || this.kind === "tooManyAttempts";
  }
}

export function isRegion(x: unknown): x is Region {
  return x === "us" || x === "outsideUS" || x === "japan";
}

export function mapError(code: string, message: string): DexcomError {
  switch (true) {
    case code === "SessionIdNotFound" || code === "SessionNotValid":
      return new DexcomError("sessionInvalid", "Dexcom session expired");
    case code === "AccountPasswordInvalid":
    case code === "SSO_InternalError" && message.includes("Cannot Authenticate"):
      return new DexcomError("invalidCredentials", "Dexcom rejected the username or password");
    case code === "SSO_AuthenticateAccountNotFound":
      return new DexcomError("accountNotFound", "No Dexcom account with that username in this region");
    case code.startsWith("SSO_AuthenticateMaxAttempts"):
      return new DexcomError("tooManyAttempts", "Too many sign-in attempts; Dexcom locked the account temporarily");
    default:
      return new DexcomError("server", `Dexcom error ${code}${message ? `: ${message}` : ""}`);
  }
}

/** Parses `Date(1699999999000)` / `Date(1699999999000-0500)` into Unix seconds. */
export function parseShareDate(s: string): number | null {
  const m = /\((\d+)/.exec(s);
  return m ? Math.floor(Number(m[1]) / 1000) : null;
}

export function parseReadings(raw: unknown): Reading[] {
  if (!Array.isArray(raw)) throw new DexcomError("server", "Unexpected readings response");
  const byTime = new Map<number, Reading>();
  for (const r of raw as Record<string, unknown>[]) {
    const t = typeof r.WT === "string" ? parseShareDate(r.WT) : null;
    if (t === null || typeof r.Value !== "number") continue;
    const trend: Trend =
      typeof r.Trend === "string" && (TRENDS as string[]).includes(r.Trend)
        ? (r.Trend as Trend)
        : typeof r.Trend === "number"
          ? (TRENDS[r.Trend] ?? "None")
          : "None";
    byTime.set(t, { t, v: r.Value, trend });
  }
  return [...byTime.values()].sort((a, b) => a.t - b.t);
}

export interface Session {
  accountId?: string;
  sessionId?: string;
}

export class DexcomClient {
  constructor(
    private readonly credentials: Credentials,
    /** Mutated in place so callers can persist the account and session IDs between polls. */
    readonly session: Session = {},
  ) {}

  async authenticate(): Promise<void> {
    const { username, password, region } = this.credentials;
    const applicationId = APPLICATION_IDS[region];
    if (!this.session.accountId) {
      const accountId = await this.post<string>("General/AuthenticatePublisherAccount", {}, {
        accountName: username, password, applicationId,
      });
      if (!isValidId(accountId)) throw new DexcomError("invalidCredentials", "Dexcom rejected the username or password");
      this.session.accountId = accountId;
    }
    const sessionId = await this.post<string>("General/LoginPublisherAccountById", {}, {
      accountId: this.session.accountId, password, applicationId,
    });
    if (!isValidId(sessionId)) throw new DexcomError("invalidCredentials", "Dexcom rejected the username or password");
    this.session.sessionId = sessionId;
  }

  async readings(minutes: number, maxCount: number): Promise<Reading[]> {
    if (!this.session.sessionId) await this.authenticate();
    try {
      return await this.fetchReadings(minutes, maxCount);
    } catch (e) {
      if (!(e instanceof DexcomError) || e.kind !== "sessionInvalid") throw e;
      this.session.sessionId = undefined;
      await this.authenticate();
      return await this.fetchReadings(minutes, maxCount);
    }
  }

  private async fetchReadings(minutes: number, maxCount: number): Promise<Reading[]> {
    const raw = await this.post<unknown>("Publisher/ReadPublisherLatestGlucoseValues", {
      sessionId: this.session.sessionId!,
      minutes: String(Math.min(Math.max(minutes, 1), 1440)),
      maxCount: String(Math.min(Math.max(maxCount, 1), 288)),
    }, {});
    return parseReadings(raw);
  }

  private async post<T>(path: string, query: Record<string, string>, body: Record<string, string>): Promise<T> {
    const url = new URL(path, BASE_URLS[this.credentials.region]);
    for (const [k, v] of Object.entries(query)) url.searchParams.set(k, v);
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json", accept: "application/json" },
      body: JSON.stringify(body),
    });
    const text = await res.text();
    let json: unknown;
    try {
      json = JSON.parse(text);
    } catch {
      throw new DexcomError("server", `Dexcom returned HTTP ${res.status} with a non-JSON body`);
    }
    if (!res.ok) {
      const err = (json ?? {}) as { Code?: string; Message?: string };
      throw err.Code ? mapError(err.Code, err.Message ?? "") : new DexcomError("server", `Dexcom HTTP ${res.status}`);
    }
    return json as T;
  }
}

function isValidId(id: unknown): id is string {
  return typeof id === "string" && UUID_RE.test(id) && id !== NULL_UUID;
}
