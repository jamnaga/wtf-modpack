/**
 * gdc-status — Cloudflare Worker
 *
 * Proxy verso il pannello MCSManager di GangDrogaCity.
 *  - GET  /status   stato pulito del server (cacheato pochi secondi)
 *  - POST /restart   avvia il riavvio dell'istanza via API pannello (token-protetto)
 *
 * La API key del pannello vive SOLO qui come secret (`wrangler secret put API_KEY`),
 * il client/mod non la vede mai.
 */

const STATUS_TTL_SECONDS = 3;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") {
      return cors(new Response(null, { status: 204 }));
    }

    if (url.pathname === "/status" || url.pathname === "/") {
      return handleStatus(env, ctx);
    }

    if (url.pathname === "/restart") {
      if (request.method !== "POST") return cors(json({ error: "method not allowed" }, 405));
      return handleRestart(request, env);
    }

    return cors(json({ error: "not found" }, 404));
  },
};

// ---- /status ----

async function handleStatus(env, ctx) {
  const cache = caches.default;
  const cacheKey = new Request("https://gdc-status/__status", { method: "GET" });

  const cached = await cache.match(cacheKey);
  if (cached) return cors(cached);

  let payload;
  try {
    const res = await fetch(panelUrl(env, "api/instance"), {
      headers: { Accept: "application/json" },
      cf: { cacheTtl: 0 },
    });
    const body = await res.json();
    payload = clean(body);
  } catch (e) {
    // pannello irraggiungibile: trattalo come offline, senza dettagli sensibili
    return cors(json({ online: false, state: "unknown", error: "panel_unreachable", ts: Date.now() }, 200));
  }

  const response = json(payload, 200, {
    "Cache-Control": `public, max-age=${STATUS_TTL_SECONDS}`,
  });
  ctx.waitUntil(cache.put(cacheKey, response.clone()));
  return cors(response);
}

function clean(panelJson) {
  const data = (panelJson && panelJson.data) || {};
  const info = data.info || {};
  const code = typeof data.status === "number" ? data.status : null;
  return {
    online: code === 3 && info.mcPingOnline === true,
    state: mapState(code),
    players: {
      current: numOrNull(info.currentPlayers),
      max: numOrNull(info.maxPlayers),
    },
    version: info.version || null,
    latency: numOrNull(info.latency),
    ts: Date.now(),
  };
}

function mapState(code) {
  switch (code) {
    case 3: return "running";
    case 2: return "starting";
    case 1: return "stopping";
    case 0: return "stopped";
    case -1: return "busy";
    default: return "unknown";
  }
}

// ---- /restart ----

async function handleRestart(request, env) {
  const auth = request.headers.get("Authorization") || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!env.RESTART_TOKEN || token !== env.RESTART_TOKEN) {
    return cors(json({ error: "unauthorized" }, 401));
  }

  const path = env.RESTART_PATH || "api/protected_instance/restart";
  try {
    const res = await fetch(panelUrl(env, path), { headers: { Accept: "application/json" } });
    const body = await res.json().catch(() => ({}));
    const ok = res.ok && (body.status === 200 || body.data === true || body.data === undefined);
    return cors(json({ ok, status: body.status ?? res.status }, ok ? 200 : 502));
  } catch (e) {
    return cors(json({ ok: false, error: "panel_unreachable" }, 502));
  }
}

// ---- helpers ----

function panelUrl(env, path) {
  const base = (env.PANEL_BASE || "").replace(/\/+$/, "");
  const p = String(path).replace(/^\/+/, "");
  const u = new URL(`${base}/${p}`);
  u.searchParams.set("apikey", env.API_KEY || "");
  u.searchParams.set("daemonId", env.DAEMON_ID || "");
  u.searchParams.set("uuid", env.INSTANCE_UUID || "");
  return u.toString();
}

function numOrNull(v) {
  return typeof v === "number" ? v : null;
}

function json(obj, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8", ...extraHeaders },
  });
}

function cors(response) {
  const h = new Headers(response.headers);
  h.set("Access-Control-Allow-Origin", "*");
  h.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  h.set("Access-Control-Allow-Headers", "Authorization, Content-Type");
  return new Response(response.body, { status: response.status, headers: h });
}
