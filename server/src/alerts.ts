// Mirror of IsletKit's AlertEngine / ActivityPolicy / GlucoseActivityState (Packages/IsletKit/Sources/IsletKit/Alerts.swift).
// Keep the two in sync: the app evaluates the same rules locally for its own UI.

export type Trend =
  | "None" | "DoubleUp" | "SingleUp" | "FortyFiveUp" | "Flat"
  | "FortyFiveDown" | "SingleDown" | "DoubleDown" | "NotComputable" | "RateOutOfRange";

/** Declaration order is priority order, as in Swift. */
export const ALERT_KINDS = ["urgentLow", "low", "fallingFast", "high", "risingFast"] as const;
export type AlertKind = (typeof ALERT_KINDS)[number];

export const ALERT_TITLES: Record<AlertKind, string> = {
  urgentLow: "Urgent Low",
  low: "Low",
  fallingFast: "Falling Fast",
  high: "High",
  risingFast: "Rising Fast",
};

export const TREND_ARROWS: Record<Trend, string> = {
  DoubleUp: "⇈", SingleUp: "↑", FortyFiveUp: "↗", Flat: "→", FortyFiveDown: "↘",
  SingleDown: "↓", DoubleDown: "⇊", None: "–", NotComputable: "–", RateOutOfRange: "–",
};

/** A CGM reading. `t` is Unix seconds, `v` is mg/dL. */
export interface Reading {
  t: number;
  v: number;
  trend: Trend;
}

export interface AlertSettings {
  urgentLowEnabled: boolean;
  urgentLow: number;
  lowEnabled: boolean;
  low: number;
  highEnabled: boolean;
  high: number;
  risingEnabled: boolean;
  riseRate: number;
  fallingEnabled: boolean;
  fallRate: number;
  clearAfterMinutes: number;
  alwaysOn: boolean;
}

export type GlucoseUnit = "mgdL" | "mmolL";

export interface Settings {
  unit: GlucoseUnit;
  targetLow: number;
  targetHigh: number;
  alerts: AlertSettings;
}

export const DEFAULT_SETTINGS: Settings = {
  unit: "mgdL",
  targetLow: 70,
  targetHigh: 180,
  alerts: {
    urgentLowEnabled: true,
    urgentLow: 55,
    lowEnabled: true,
    low: 70,
    highEnabled: true,
    high: 220,
    risingEnabled: true,
    riseRate: 2,
    fallingEnabled: true,
    fallRate: 2,
    clearAfterMinutes: 20,
    alwaysOn: false,
  },
};

/** Merge untrusted input (the app's encoded IsletSettings) over defaults, keeping only well-typed fields. */
export function normalizeSettings(input: unknown): Settings {
  const src = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
  const srcAlerts = (src.alerts && typeof src.alerts === "object" ? src.alerts : {}) as Record<string, unknown>;
  const pick = <T extends object>(defaults: T, from: Record<string, unknown>): T => {
    const out = { ...defaults } as Record<string, unknown>;
    for (const [k, d] of Object.entries(defaults)) {
      if (typeof from[k] === typeof d && (typeof d !== "number" || Number.isFinite(from[k]))) out[k] = from[k];
    }
    return out as T;
  };
  const settings = pick({ ...DEFAULT_SETTINGS, alerts: undefined } as unknown as Omit<Settings, "alerts">, src) as Settings;
  settings.alerts = pick(DEFAULT_SETTINGS.alerts, srcAlerts);
  if (settings.unit !== "mgdL" && settings.unit !== "mmolL") settings.unit = "mgdL";
  return settings;
}

export const STALE_AFTER = 15 * 60;

/** mg/dL per minute from a least-squares fit over readings within `window` seconds of the latest. */
export function rate(readings: Reading[], window = 15 * 60): number | null {
  const last = readings.at(-1);
  if (!last) return null;
  const recent = readings.filter((r) => last.t - r.t <= window + 30);
  if (recent.length < 2) return null;
  const xs = recent.map((r) => (r.t - last.t) / 60);
  const ys = recent.map((r) => r.v);
  const mx = xs.reduce((a, b) => a + b, 0) / xs.length;
  const my = ys.reduce((a, b) => a + b, 0) / ys.length;
  let num = 0;
  let den = 0;
  xs.forEach((x, i) => {
    num += (x - mx) * (ys[i]! - my);
    den += (x - mx) ** 2;
  });
  return den > 0 ? num / den : null;
}

export function delta(readings: Reading[]): number | null {
  if (readings.length < 2) return null;
  const last = readings.at(-1)!;
  const prev = readings.at(-2)!;
  return last.t - prev.t <= 11 * 60 ? last.v - prev.v : null;
}

/** A glucose alert clears only once the value is this far back inside its threshold (mg/dL). */
export const CLEAR_MARGIN = 5;
/** Likewise for rate alerts (mg/dL per minute), capped at a quarter of the threshold. */
export const RATE_CLEAR_MARGIN = 0.5;

export function isStale(readings: Reading[], now: number): boolean {
  const latest = readings.at(-1);
  return !latest || now - latest.t > STALE_AFTER;
}

/**
 * Active alert conditions, highest priority first. Readings must be sorted oldest first.
 *
 * `previous` is the result of the last evaluation. An alert that was already active stays active
 * until the value is a margin back inside its threshold, so readings hovering around a threshold
 * don't flip the alert on and off. Stale data yields no alerts; callers handle signal loss.
 */
export function evaluate(readings: Reading[], s: AlertSettings, now: number, previous: AlertKind[] = []): AlertKind[] {
  const latest = readings.at(-1);
  if (!latest || isStale(readings, now)) return [];
  const was = (k: AlertKind) => previous.includes(k);
  const v = latest.v;
  const result: AlertKind[] = [];
  if (s.urgentLowEnabled && (v < s.urgentLow || (was("urgentLow") && v < s.urgentLow + CLEAR_MARGIN))) {
    result.push("urgentLow");
  } else if (s.lowEnabled && (v < s.low || ((was("low") || was("urgentLow")) && v < s.low + CLEAR_MARGIN))) {
    result.push("low");
  }
  if (s.highEnabled && (v > s.high || (was("high") && v > s.high - CLEAR_MARGIN))) result.push("high");
  const r = rate(readings);
  if (r !== null) {
    const rise = s.riseRate - Math.min(RATE_CLEAR_MARGIN, s.riseRate / 4);
    const fall = s.fallRate - Math.min(RATE_CLEAR_MARGIN, s.fallRate / 4);
    if (s.risingEnabled && (r >= s.riseRate || (was("risingFast") && r >= rise))) result.push("risingFast");
    if (s.fallingEnabled && (r <= -s.fallRate || (was("fallingFast") && r <= -fall))) result.push("fallingFast");
  }
  return result.sort((a, b) => ALERT_KINDS.indexOf(a) - ALERT_KINDS.indexOf(b));
}

/** When each alert kind was last active (Unix seconds). */
export type AlertHistory = Partial<Record<AlertKind, number>>;

/**
 * Which of `alerts` deserve a sound: those not active at any point in the last `clearAfter` seconds.
 * An alert announces once per episode, however often its condition flickers. Returns the kinds to
 * announce and the updated history. Urgent low also marks low as seen, so recovering from urgent
 * low through low stays quiet.
 */
export function announce(alerts: AlertKind[], history: AlertHistory, now: number, clearAfter: number):
  { announce: AlertKind[]; history: AlertHistory } {
  const fresh = alerts.filter((a) => {
    const seen = history[a];
    return seen === undefined || now - seen >= clearAfter;
  });
  const next: AlertHistory = { ...history };
  for (const a of alerts) next[a] = now;
  if (alerts.includes("urgentLow")) next.low = now;
  return { announce: fresh, history: next };
}

export type Decision = "start" | "update" | "end" | "none";

/**
 * What to do with the Live Activity after a poll. With `stale` (no reading for 15 minutes), a running
 * activity is held: silence isn't evidence of recovery, and the activity shows itself as stale.
 */
export function decide(p: {
  alerts: AlertKind[];
  isRunning: boolean;
  keepAlive: boolean;
  lastAlertAt?: number;
  clearAfter: number;
  now: number;
  stale?: boolean;
}): Decision {
  if (p.alerts.length > 0 || p.keepAlive) return p.isRunning ? "update" : "start";
  if (p.stale && p.isRunning) return "update";
  if (!p.isRunning) return "none";
  if (p.lastAlertAt !== undefined && p.now - p.lastAlertAt < p.clearAfter) return "update";
  return "end";
}

/** Matches Swift's GlucoseActivityState Codable encoding exactly (it's sent as APNs `content-state`). */
export interface ActivityState {
  value: number;
  trend: Trend;
  timestamp: number;
  delta?: number;
  alerts: AlertKind[];
  unit: GlucoseUnit;
  targetLow: number;
  targetHigh: number;
  urgentLow: number;
  history: { m: number; v: number }[];
}

export const HISTORY_MINUTES = 120;

export function activityState(readings: Reading[], settings: Settings, alerts: AlertKind[]): ActivityState | null {
  const latest = readings.at(-1);
  if (!latest) return null;
  const d = delta(readings);
  return {
    value: latest.v,
    trend: latest.trend,
    timestamp: latest.t,
    ...(d === null ? {} : { delta: d }),
    alerts,
    unit: settings.unit,
    targetLow: settings.targetLow,
    targetHigh: settings.targetHigh,
    urgentLow: settings.alerts.urgentLow,
    history: readings
      .map((r) => ({ m: Math.trunc((latest.t - r.t) / 60), v: r.v }))
      .filter((p) => p.m <= HISTORY_MINUTES),
  };
}

export function formatValue(mgdL: number, unit: GlucoseUnit): string {
  if (mgdL < 40) return "LOW";
  if (mgdL > 400) return "HIGH";
  return unit === "mgdL" ? String(Math.round(mgdL)) : (mgdL / 18.0182).toFixed(1);
}

/** One-line alert text, e.g. "245 mg/dL ↑". */
export function describe(state: ActivityState): string {
  const unit = state.unit === "mgdL" ? "mg/dL" : "mmol/L";
  return `${formatValue(state.value, state.unit)} ${unit} ${TREND_ARROWS[state.trend]}`;
}
