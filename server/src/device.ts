import { DurableObject } from "cloudflare:workers";
import {
  activityState, ALERT_TITLES, announce, decide, describe, evaluate, isStale, normalizeSettings, STALE_AFTER,
  type ActivityState, type AlertHistory, type AlertKind, type Reading, type Settings,
} from "./alerts";
import { payload, sendLiveActivity, type ApnsConfig, type ApnsEnvironment, type LiveActivityEvent } from "./apns";
import { DexcomClient, DexcomError, isRegion, type Credentials, type Session } from "./dexcom";
import { open, seal } from "./secrets";
import type { Env } from "./index";

/** iOS ends Live Activities after 8 hours; treat ours as gone a little before that. */
const ACTIVITY_LIFETIME = 8 * 3600 - 120;
/** Fetch enough history for the two-hour sparkline plus the rate-of-change window. */
const FETCH_MINUTES = 150;
const FETCH_COUNT = 32;

interface DeviceState {
  credentials: string; // sealed Credentials
  session: Session;
  settings: Settings;
  environment: ApnsEnvironment;
  pushToStartToken?: string;
  /** Our belief about the device's Live Activity. `token` arrives from the app after a push-to-start. */
  activity?: { id?: string; token?: string; startedAt: number };
  pinned: boolean;
  lastAlertAt?: number;
  lastAlerts: AlertKind[];
  /** When each alert kind was last active; an alert sounds once per episode, not on every flicker. */
  alertHistory?: AlertHistory;
  /** Alerts the user dismissed; don't restart for these until conditions clear. */
  suppressed: AlertKind[];
  lastReading?: Reading;
  lastPushedReadingAt?: number;
  lastPollAt?: number;
  failures: number;
  lastError?: string;
  /** Set when Dexcom rejects the credentials; polling stops until the app re-registers. */
  fatalError?: string;
  lastPush?: { at: number; event: string; status: number; reason?: string };
}

export interface RegisterInput {
  credentials: Credentials;
  settings?: unknown;
  environment?: ApnsEnvironment;
  pushToStartToken?: string;
}

export interface PatchInput {
  settings?: unknown;
  environment?: ApnsEnvironment;
  pinned?: boolean;
  pushToStartToken?: string | null;
  /** The app reports the running activity's update token, or `null` when the activity ended. */
  activity?: { id: string; token: string } | null;
  /** With `activity: null`: the user ended it on purpose, so don't restart for the current alerts. */
  suppress?: boolean;
}

export type Result<T = unknown> = { ok: true; value: T } | { ok: false; status: number; error: string };

export class Device extends DurableObject<Env> {
  private state?: DeviceState;

  // MARK: RPC

  async register(input: RegisterInput): Promise<Result<Record<string, unknown>>> {
    const { credentials } = input;
    if (!credentials?.username || !credentials.password || !isRegion(credentials.region)) {
      return { ok: false, status: 400, error: "credentials.username, .password and .region are required" };
    }
    // Validate up front so the app can show a sign-in error immediately.
    const client = new DexcomClient(credentials);
    try {
      await client.authenticate();
    } catch (e) {
      return { ok: false, status: e instanceof DexcomError && e.isFatal ? 401 : 502, error: String((e as Error).message) };
    }
    const previous = await this.load();
    this.state = {
      credentials: await seal(credentials, this.env.CREDENTIALS_KEY),
      session: client.session,
      settings: normalizeSettings(input.settings),
      environment: input.environment === "production" ? "production" : "sandbox",
      pushToStartToken: input.pushToStartToken ?? previous?.pushToStartToken,
      activity: previous?.activity,
      pinned: previous?.pinned ?? false,
      lastAlerts: previous?.lastAlerts ?? [],
      alertHistory: previous?.alertHistory,
      suppressed: previous?.suppressed ?? [],
      failures: 0,
    };
    await this.save();
    await this.ctx.storage.setAlarm(Date.now() + 1000);
    return { ok: true, value: await this.status() };
  }

  async patch(input: PatchInput): Promise<Result<Record<string, unknown>>> {
    const st = await this.load();
    if (!st) return { ok: false, status: 404, error: "Device not registered" };
    let pollSoon = false;
    if (input.settings !== undefined) {
      st.settings = normalizeSettings(input.settings);
      pollSoon = true;
    }
    if (input.environment === "sandbox" || input.environment === "production") st.environment = input.environment;
    if (input.pinned !== undefined) {
      st.pinned = input.pinned;
      if (input.pinned) st.suppressed = [];
    }
    if (input.pushToStartToken !== undefined) st.pushToStartToken = input.pushToStartToken ?? undefined;
    if (input.activity === null) {
      st.activity = undefined;
      st.pinned = false;
      if (input.suppress) st.suppressed = [...st.lastAlerts];
    } else if (input.activity) {
      st.activity = { startedAt: st.activity?.startedAt ?? now(), ...input.activity };
    }
    await this.save();
    if (pollSoon) await this.pollSoon();
    return { ok: true, value: await this.status() };
  }

  async status(): Promise<Record<string, unknown>> {
    const st = await this.load();
    if (!st) return { registered: false };
    const alarm = await this.ctx.storage.getAlarm();
    return {
      registered: true,
      environment: st.environment,
      polling: alarm !== null,
      nextPollAt: alarm ? Math.floor(alarm / 1000) : null,
      lastPollAt: st.lastPollAt ?? null,
      lastReading: st.lastReading ?? null,
      alerts: st.lastAlerts,
      pinned: st.pinned,
      activity: st.activity ? { running: true, hasToken: !!st.activity.token, startedAt: st.activity.startedAt } : { running: false },
      hasPushToStartToken: !!st.pushToStartToken,
      lastPush: st.lastPush ?? null,
      error: st.fatalError ?? st.lastError ?? null,
    };
  }

  async remove(): Promise<void> {
    const st = await this.load();
    if (st?.activity?.token && st.lastReading) {
      const state = activityState([st.lastReading], st.settings, []);
      if (state) await this.push(st, st.activity.token, { event: "end", state }).catch(() => {});
    }
    this.state = undefined;
    await this.ctx.storage.deleteAlarm();
    await this.ctx.storage.deleteAll();
  }

  async pollNow(): Promise<Record<string, unknown>> {
    await this.poll();
    return this.status();
  }

  // MARK: Polling

  override async alarm(): Promise<void> {
    await this.poll();
  }

  private async poll(): Promise<void> {
    const st = await this.load();
    if (!st || st.fatalError) return;
    const t = now();

    let readings: Reading[];
    try {
      const credentials = await open<Credentials>(st.credentials, this.env.CREDENTIALS_KEY);
      const client = new DexcomClient(credentials, st.session);
      readings = await client.readings(FETCH_MINUTES, FETCH_COUNT);
      st.session = client.session;
      st.failures = 0;
      st.lastError = undefined;
    } catch (e) {
      st.failures += 1;
      st.lastError = String((e as Error).message);
      if (e instanceof DexcomError && e.isFatal) st.fatalError = st.lastError;
      await this.save();
      await this.scheduleNext();
      return;
    }

    st.lastPollAt = t;
    st.lastReading = readings.at(-1) ?? st.lastReading;
    if (st.activity && t - st.activity.startedAt > ACTIVITY_LIFETIME) st.activity = undefined;

    const stale = isStale(readings, t);
    const alerts = evaluate(readings, st.settings.alerts, t, st.lastAlerts);
    let fresh: AlertKind[] = [];
    if (stale) {
      // Signal loss isn't recovery: keep the alert clock running so a running activity stays up and
      // still lingers for the full clear-after period once readings resume. Alerts, suppressions and
      // history are left as they were.
      if (st.activity && st.lastAlerts.length > 0) st.lastAlertAt = t;
    } else {
      if (alerts.length > 0) st.lastAlertAt = t;
      else st.suppressed = [];
      const result = announce(alerts, st.alertHistory ?? {}, t, st.settings.alerts.clearAfterMinutes * 60);
      fresh = result.announce;
      st.alertHistory = result.history;
    }

    // While stale, show the last known alerts rather than none.
    const state = activityState(readings, st.settings, stale ? st.lastAlerts : alerts);
    if (state) await this.applyPolicy(st, state, alerts, fresh, stale, t);

    if (!stale) st.lastAlerts = alerts;
    await this.save();
    await this.scheduleNext();
  }

  /** `fresh` are the alerts to announce with sound; `stale` means no reading for 15 minutes. */
  private async applyPolicy(
    st: DeviceState, state: ActivityState, alerts: AlertKind[], fresh: AlertKind[], stale: boolean, t: number,
  ): Promise<void> {
    const keepAlive = st.pinned || st.settings.alerts.alwaysOn;
    const decision = decide({
      alerts,
      isRunning: !!st.activity,
      keepAlive,
      lastAlertAt: st.lastAlertAt,
      clearAfter: st.settings.alerts.clearAfterMinutes * 60,
      now: t,
      stale,
    });
    const top = fresh[0] ?? alerts[0];
    const alert = {
      title: top ? ALERT_TITLES[top] : "Glucose",
      body: describe(state),
      sound: fresh.length > 0,
    };

    switch (decision) {
      case "start": {
        const onlySuppressed = alerts.length > 0 && alerts.every((a) => st.suppressed.includes(a));
        if (onlySuppressed && !keepAlive) return;
        if (!st.pushToStartToken) {
          st.lastError = "Can't start a Live Activity yet: open Islet once so it can register for push-to-start";
          return;
        }
        const result = await this.push(st, st.pushToStartToken, { event: "start", state, alert });
        if (result.ok) st.activity = { startedAt: t };
        else if (result.tokenInvalid) st.pushToStartToken = undefined;
        break;
      }
      case "update": {
        const token = st.activity?.token;
        // Only push when there's something new: a fresh reading or a change in alerts.
        if (!token || (st.lastPushedReadingAt === state.timestamp && fresh.length === 0 && sameAlerts(st.lastAlerts, state.alerts))) return;
        const result = await this.push(st, token, { event: "update", state, alert: fresh.length > 0 ? alert : undefined });
        if (result.tokenInvalid) st.activity = undefined;
        break;
      }
      case "end": {
        const token = st.activity?.token;
        if (token) await this.push(st, token, { event: "end", state });
        st.activity = undefined;
        break;
      }
      case "none":
        break;
    }
  }

  private async push(st: DeviceState, token: string, e: LiveActivityEvent) {
    const config: ApnsConfig = {
      teamId: this.env.APNS_TEAM_ID,
      keyId: this.env.APNS_KEY_ID,
      privateKey: this.env.APNS_PRIVATE_KEY,
      topic: this.env.APNS_TOPIC,
    };
    const t = now();
    const urgent = e.event === "start" || (e.event === "update" && !!e.alert) || e.state.alerts.length > 0;
    try {
      const result = await sendLiveActivity(config, st.environment, token, payload(e, t, STALE_AFTER), urgent);
      st.lastPush = { at: t, event: e.event, status: result.status, reason: result.reason };
      if (result.ok) st.lastPushedReadingAt = e.state.timestamp;
      return result;
    } catch (err) {
      st.lastPush = { at: t, event: e.event, status: 0, reason: String((err as Error).message) };
      return { ok: false, status: 0, tokenInvalid: false };
    }
  }

  /** Poll just after the next reading is due (Dexcom publishes every 5 minutes), backing off on errors. */
  private async scheduleNext(): Promise<void> {
    const st = this.state;
    if (!st || st.fatalError) {
      await this.ctx.storage.deleteAlarm();
      return;
    }
    const nowMs = Date.now();
    let next: number;
    if (st.failures > 0) {
      next = nowMs + Math.min(60_000 * 2 ** (st.failures - 1), 15 * 60_000);
    } else if (st.lastReading) {
      const due = (st.lastReading.t + 5 * 60 + 15) * 1000;
      const age = nowMs / 1000 - st.lastReading.t;
      if (due > nowMs + 5_000) next = Math.min(due, nowMs + 330_000);
      else next = nowMs + (age > 30 * 60 ? 5 * 60_000 : 60_000); // late reading, or sensor offline
    } else {
      next = nowMs + 5 * 60_000;
    }
    await this.ctx.storage.setAlarm(next);
  }

  /** Re-evaluate shortly after a settings change, coalescing bursts of edits. */
  private async pollSoon(): Promise<void> {
    const soon = Date.now() + 10_000;
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > soon) await this.ctx.storage.setAlarm(soon);
  }

  // MARK: Storage
  // One in-memory object shared by every handler, so concurrent requests (e.g. a token arriving
  // while a poll awaits Dexcom) mutate the same state instead of overwriting each other's copies.

  private async load(): Promise<DeviceState | undefined> {
    this.state ??= await this.ctx.storage.get<DeviceState>("state");
    return this.state;
  }

  private async save(): Promise<void> {
    if (this.state) await this.ctx.storage.put("state", this.state);
  }
}

function now(): number {
  return Math.floor(Date.now() / 1000);
}

function sameAlerts(a: AlertKind[], b: AlertKind[]): boolean {
  return a.length === b.length && a.every((x, i) => x === b[i]);
}
