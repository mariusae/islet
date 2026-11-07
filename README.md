# Islet

An iPhone app that shows your Dexcom CGM glucose with a clean, range-colored chart, and puts a
**Live Activity** on your Lock Screen, Dynamic Island and Apple Watch whenever something needs
attention: low, urgent low, high, or rising/falling fast. Every threshold is configurable.

> Islet uses **Dexcom Share**, the unofficial, undocumented API behind the Dexcom Follow app. It can
> change without notice. Islet is not a medical device and isn't affiliated with Dexcom.

## Layout

| Path | What |
| --- | --- |
| `Islet/` | SwiftUI app: sign-in, dashboard, chart, settings, Live Activity control |
| `IsletWidgets/` | Widget extension: Live Activity UI (Lock Screen, Dynamic Island, Watch Smart Stack) |
| `Packages/IsletKit/` | Shared Swift package: Dexcom Share client, models, alert engine, shared views |
| `server/` | Cloudflare Worker that polls Dexcom and drives the Live Activity over APNs |
| `Config/` | Info.plists and entitlements |

## How alerts reach the Lock Screen

iOS only lets an app *start* a Live Activity while it's in the foreground, and background refresh
runs far less often than every 5 minutes. So the reliable path is a server:

1. The app registers with the Worker: Dexcom credentials (stored AES-GCM encrypted), alert
   settings, and its ActivityKit **push-to-start token**.
2. A Durable Object per device polls Dexcom on an alarm timed just after each reading lands, and runs
   the same alert rules as the app (`server/src/alerts.ts` mirrors `IsletKit/Alerts.swift`).
3. When a condition triggers, it sends a **push-to-start** Live Activity push. iOS starts the activity
   and wakes the app briefly to report the activity's **update token**.
4. Each new reading is pushed as an update. Escalations (e.g. High → High + Rising Fast) are sent
   with an alert so the screen lights up and the watch taps. After conditions have been clear for the
   configured time, an end push removes the activity.

Without a server configured, the app does the same thing locally, but only while it's open or
refreshing in the background.

Apple Watch: iOS 18+/watchOS 11+ shows iPhone Live Activities in the watch's Smart Stack
automatically. Islet supplies a dedicated compact layout (`.supplementalActivityFamilies([.small])`).

## Building the app

Requirements: Xcode 27 (iOS 18+ deployment target).

1. Open `Islet.xcodeproj`.
2. For **both** targets (`Islet` and `IsletWidgetsExtension`), under Signing & Capabilities, set your
   team and change the bundle IDs from `com.example.islet` / `com.example.islet.widgets` to your own
   (keep the widget's as `<app id>.widgets`).
3. Run on a device. Use **Explore with demo data** on the sign-in screen to try everything with
   synthetic readings.

Dexcom requirements: Share must be enabled in your Dexcom app, with at least one follower.

Unit tests for the shared package: `cd Packages/IsletKit && swift test`.

## Deploying the push server

You need a Cloudflare account (the free plan is enough: SQLite-backed Durable Objects) and an APNs
auth key.

1. **APNs key**: at developer.apple.com → Certificates, Identifiers & Profiles → Keys, create a key
   with *Apple Push Notifications service (APNs)* enabled. Download the `.p8` file and note its
   **Key ID** and your **Team ID**.
2. Configure `server/wrangler.jsonc`: set `APNS_TOPIC` to your app's bundle ID, plus `APNS_KEY_ID`
   and `APNS_TEAM_ID`.
3. Install dependencies, then set the secrets and deploy:

```bash
cd server && npm install
```

```bash
npx wrangler secret put ISLET_API_KEY
```

```bash
npx wrangler secret put CREDENTIALS_KEY
```

```bash
npx wrangler secret put APNS_PRIVATE_KEY < AuthKey_XXXXXXXXXX.p8
```

```bash
npx wrangler deploy
```

Use a long random value for `ISLET_API_KEY`. For `CREDENTIALS_KEY`, use the output of
`openssl rand -base64 32`.

4. In the app, sign in to Dexcom. Then open **Settings → Push server**, enter the Worker URL and
   API key, and tap **Connect**. The section shows polling status, whether the push-to-start token
   has arrived, and the result of the last push.

   To build both values into the app instead, copy `Config/Local.xcconfig.example` to
   `Config/Local.xcconfig` (git-ignored) and fill in `ISLET_SERVER_HOST` and `ISLET_API_KEY`.
   Settings is then prefilled, and anything entered there still takes precedence.

Debug builds register as APNs `sandbox` and Release builds as `production`. They must match how the
app was signed: Xcode runs use sandbox, and TestFlight/App Store builds use production.

Server checks: `npm test` (alert engine, Share parsing, encryption, APNs JWT/payloads) and
`npm run typecheck`. Debugging: `GET /v1/devices/<id>` shows status, and `POST /v1/devices/<id>/poll`
forces a poll (both need the API key).

## Known limitations

- Push-to-start delivery and the background wake that reports the activity's update token are
  handled by iOS and can be delayed; if the token never arrives, the activity shows the start
  reading and goes stale rather than updating.
- iOS ends Live Activities after 8 hours; the server starts a fresh one if conditions persist.
- Dexcom Share data lags the sensor by a few minutes.
