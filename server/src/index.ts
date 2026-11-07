// Islet push server: polls Dexcom Share for each registered device and drives its glucose
// Live Activity over APNs (push-to-start, update, end), so alerts appear even when the app isn't running.
//
// API (all routes need `Authorization: Bearer <ISLET_API_KEY>`; :id is a device UUID chosen by the app):
//   PUT    /v1/devices/:id        register: { credentials, settings, environment, pushToStartToken? }
//   PATCH  /v1/devices/:id        update:   { settings?, pinned?, pushToStartToken?, activity?, suppress? }
//   GET    /v1/devices/:id        status
//   DELETE /v1/devices/:id        sign out: ends the activity and erases everything
//   POST   /v1/devices/:id/poll   poll Dexcom now (debugging)
import { Device, type PatchInput, type RegisterInput, type Result } from "./device";

export { Device };

export interface Env {
  DEVICES: DurableObjectNamespace<Device>;
  ISLET_API_KEY: string;
  CREDENTIALS_KEY: string;
  APNS_PRIVATE_KEY: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_TOPIC: string;
}

const ROUTE = /^\/v1\/devices\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(\/poll)?$/i;

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") return json({ ok: true });

    if (!env.ISLET_API_KEY || !(await authorized(request, env.ISLET_API_KEY))) {
      return json({ error: "Unauthorized" }, 401);
    }

    const match = ROUTE.exec(url.pathname);
    if (!match) return json({ error: "Not found" }, 404);
    const device = env.DEVICES.get(env.DEVICES.idFromName(match[1]!.toLowerCase()));

    if (match[2]) {
      return request.method === "POST" ? json(await device.pollNow()) : json({ error: "Method not allowed" }, 405);
    }

    switch (request.method) {
      case "GET":
        return json(await device.status());
      case "PUT":
        return respond(await device.register(await body<RegisterInput>(request)));
      case "PATCH":
        return respond(await device.patch(await body<PatchInput>(request)));
      case "DELETE":
        await device.remove();
        return new Response(null, { status: 204 });
      default:
        return json({ error: "Method not allowed" }, 405);
    }
  },
} satisfies ExportedHandler<Env>;

async function authorized(request: Request, apiKey: string): Promise<boolean> {
  const header = request.headers.get("authorization") ?? "";
  const given = new TextEncoder().encode(header);
  const expected = new TextEncoder().encode(`Bearer ${apiKey}`);
  return given.byteLength === expected.byteLength && crypto.subtle.timingSafeEqual(given, expected);
}

async function body<T>(request: Request): Promise<T> {
  try {
    return (await request.json()) as T;
  } catch {
    return {} as T;
  }
}

function respond(result: Result): Response {
  return result.ok ? json(result.value) : json({ error: result.error }, result.status);
}

function json(value: unknown, status = 200): Response {
  return Response.json(value, { status });
}
