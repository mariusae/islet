import { describe, expect, it } from "vitest";
import {
  activityState, announce, decide, DEFAULT_SETTINGS, evaluate, normalizeSettings, type Reading,
} from "../src/alerts";
import { payload, providerToken } from "../src/apns";
import { mapError, parseReadings } from "../src/dexcom";
import { open, seal } from "../src/secrets";

const NOW = 1_700_000_000;
const series = (values: number[]): Reading[] =>
  values.map((v, i) => ({ t: NOW + (i - values.length + 1) * 300, v, trend: "Flat" }));

describe("alert engine (mirrors IsletKit AlertTests)", () => {
  const s = DEFAULT_SETTINGS.alerts;

  it("detects low and urgent low", () => {
    expect(evaluate(series([80, 75, 68]), s, NOW)).toContain("low");
    const urgent = evaluate(series([60, 56, 52]), s, NOW);
    expect(urgent[0]).toBe("urgentLow");
    expect(urgent).not.toContain("low");
  });

  it("detects rapid changes", () => {
    expect(evaluate(series([100, 112, 125, 138]), s, NOW)).toEqual(["risingFast"]);
    expect(evaluate(series([150, 138, 126, 114]), s, NOW)).toEqual(["fallingFast"]);
    expect(evaluate(series([120, 121, 119, 120]), s, NOW)).toEqual([]);
  });

  it("ignores stale data", () => {
    expect(evaluate(series([40, 40, 40]), s, NOW + 3600)).toEqual([]);
  });

  it("prioritizes alerts", () => {
    expect(evaluate(series([140, 152, 164, 176]), { ...s, high: 150 }, NOW)).toEqual(["high", "risingFast"]);
  });

  it("follows the activity lifecycle", () => {
    const base = { keepAlive: false, clearAfter: 1200, now: NOW };
    expect(decide({ ...base, alerts: ["high"], isRunning: false, lastAlertAt: NOW })).toBe("start");
    expect(decide({ ...base, alerts: ["high"], isRunning: true, lastAlertAt: NOW })).toBe("update");
    expect(decide({ ...base, alerts: [], isRunning: true, lastAlertAt: NOW - 600 })).toBe("update");
    expect(decide({ ...base, alerts: [], isRunning: true, lastAlertAt: NOW - 1800 })).toBe("end");
    expect(decide({ ...base, alerts: [], isRunning: false })).toBe("none");
    expect(decide({ ...base, alerts: [], isRunning: false, keepAlive: true })).toBe("start");
  });

  it("holds a running activity through signal loss", () => {
    const base = { keepAlive: false, clearAfter: 1200, now: NOW, alerts: [] };
    expect(decide({ ...base, isRunning: true, lastAlertAt: NOW - 3600, stale: true })).toBe("update");
    expect(decide({ ...base, isRunning: false, stale: true })).toBe("none");
  });

  it("needs a margin before clearing an alert", () => {
    const high = { ...s, high: 220 };
    expect(evaluate(series([225, 223, 219]), high, NOW, ["high"])).toEqual(["high"]);
    expect(evaluate(series([225, 223, 214]), high, NOW, ["high"])).toEqual([]);
    expect(evaluate(series([214, 216, 219]), high, NOW, [])).toEqual([]);
    expect(evaluate(series([66, 68, 72]), s, NOW, ["low"])).toEqual(["low"]);
    expect(evaluate(series([66, 70, 76]), s, NOW, ["low"])).toEqual([]);
    expect(evaluate(series([50, 54, 57]), s, NOW, ["urgentLow"])[0]).toBe("urgentLow");
    expect(evaluate(series([52, 58, 62]), s, NOW, ["urgentLow"])).toEqual(["low"]);
    // Rising at ~1.7 mg/dL/min: below the 2.0 threshold, but within the 0.5 margin once active.
    expect(evaluate(series([100, 108, 117, 125]), s, NOW, ["risingFast"])).toEqual(["risingFast"]);
    expect(evaluate(series([100, 108, 117, 125]), s, NOW, [])).toEqual([]);
  });

  it("announces each alert once per episode", () => {
    const clear = 1200;
    let r = announce(["high"], {}, NOW, clear);
    expect(r.announce).toEqual(["high"]);
    // Flickers off and back on within the clear-after period: quiet.
    r = announce(["high"], r.history, NOW + 600, clear);
    expect(r.announce).toEqual([]);
    // A new kind still sounds.
    r = announce(["high", "risingFast"], r.history, NOW + 900, clear);
    expect(r.announce).toEqual(["risingFast"]);
    // Clear for the full period, then back: a new episode.
    r = announce(["high"], r.history, NOW + 900 + clear, clear);
    expect(r.announce).toEqual(["high"]);
    // Recovering from urgent low through low stays quiet.
    r = announce(["urgentLow"], {}, NOW, clear);
    expect(announce(["low"], r.history, NOW + 300, clear).announce).toEqual([]);
  });

  it("builds content-state in the app's wire format", () => {
    const state = activityState(series([170, 175, 182]), DEFAULT_SETTINGS, ["high"])!;
    expect(state).toEqual({
      value: 182, trend: "Flat", timestamp: NOW, delta: 7, alerts: ["high"], unit: "mgdL",
      targetLow: 70, targetHigh: 180, urgentLow: 55,
      history: [{ m: 10, v: 170 }, { m: 5, v: 175 }, { m: 0, v: 182 }],
    });
  });

  it("normalizes untrusted settings", () => {
    const s2 = normalizeSettings({ unit: "mmolL", targetLow: "x", alerts: { high: 200, low: null, bogus: 1 } });
    expect(s2.unit).toBe("mmolL");
    expect(s2.targetLow).toBe(70);
    expect(s2.alerts.high).toBe(200);
    expect(s2.alerts.low).toBe(70);
    expect("bogus" in s2.alerts).toBe(false);
  });
});

describe("dexcom share", () => {
  it("parses readings, sorting and de-duplicating", () => {
    const readings = parseReadings([
      { WT: "Date(1699999800000)", Value: 142, Trend: "FortyFiveUp" },
      { WT: "Date(1699999500000-0500)", Value: 131, Trend: 4 },
      { WT: "Date(1699999800000)", Value: 142, Trend: "FortyFiveUp" },
    ]);
    expect(readings).toEqual([
      { t: 1_699_999_500, v: 131, trend: "Flat" },
      { t: 1_699_999_800, v: 142, trend: "FortyFiveUp" },
    ]);
  });

  it("maps error codes", () => {
    expect(mapError("SessionNotValid", "").kind).toBe("sessionInvalid");
    expect(mapError("AccountPasswordInvalid", "").isFatal).toBe(true);
    expect(mapError("SSO_AuthenticateMaxAttemptsExceeed", "").kind).toBe("tooManyAttempts");
    expect(mapError("Whatever", "").isFatal).toBe(false);
  });
});

describe("secrets", () => {
  it("round-trips sealed credentials", async () => {
    const key = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));
    const sealed = await seal({ username: "u", password: "p", region: "us" }, key);
    expect(sealed).not.toContain("p\"");
    expect(await open(sealed, key)).toEqual({ username: "u", password: "p", region: "us" });
  });
});

describe("apns", () => {
  it("signs a verifiable ES256 provider token", async () => {
    const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
    const pkcs8 = new Uint8Array((await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer);
    const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----`;
    const jwt = await providerToken({ teamId: "TEAM123456", keyId: "KEY1234567", privateKey: pem, topic: "x" }, NOW);
    const [h, c, sig] = jwt.split(".");
    const decode = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (ch) => ch.charCodeAt(0));
    expect(JSON.parse(new TextDecoder().decode(decode(h!)))).toEqual({ alg: "ES256", kid: "KEY1234567" });
    expect(JSON.parse(new TextDecoder().decode(decode(c!)))).toEqual({ iss: "TEAM123456", iat: NOW });
    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" }, pair.publicKey, decode(sig!), new TextEncoder().encode(`${h}.${c}`));
    expect(valid).toBe(true);
  });

  it("builds push-to-start payloads", () => {
    const state = activityState(series([230, 240]), DEFAULT_SETTINGS, ["high"])!;
    const body = payload({ event: "start", state, alert: { title: "High", body: "240 mg/dL →" } }, NOW + 30, 900) as {
      aps: Record<string, unknown>;
    };
    expect(body.aps).toMatchObject({
      event: "start",
      timestamp: NOW + 30,
      "attributes-type": "GlucoseActivityAttributes",
      attributes: {},
      "content-state": state,
      "stale-date": NOW + 900,
      "input-push-token": 1,
      alert: { title: "High", body: "240 mg/dL →", sound: "default" },
    });
    const end = payload({ event: "end", state }, NOW + 30, 900) as { aps: Record<string, unknown> };
    expect(end.aps["dismissal-date"]).toBe(NOW + 30);
    expect(end.aps.alert).toBeUndefined();
    const quiet = payload({ event: "start", state, alert: { title: "Glucose", body: "240", sound: false } }, NOW, 900) as {
      aps: { alert: Record<string, unknown> };
    };
    expect(quiet.aps.alert).toEqual({ title: "Glucose", body: "240" });
  });
});
