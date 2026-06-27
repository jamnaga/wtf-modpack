/**
 * gdc-status — Cloudflare Worker
 *
 * Proxy verso il pannello MCSManager di GangDrogaCity.
 *  - GET  /status                 stato pulito del server (cacheato pochi secondi)
 *  - POST /restart?preset=noupdate riavvio singolo dell'istanza (rapido)
 *  - POST /restart?preset=update   sequenza stop -> update (sh ./update.sh) -> start,
 *                                  con attesa della fine dell'update (busy -> stopped)
 *
 * /restart richiede Authorization: Bearer <RESTART_TOKEN>.
 * La API key del pannello vive SOLO qui come secret; mod/client non la vedono mai.
 * La sequenza update gira in ctx.waitUntil: il chiamante (il server MC) viene fermato
 * dallo stop, quindi non puo' attendere lui; il Worker prosegue in background.
 */

const STATUS_TTL_SECONDS = 3;

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") return cors(new Response(null, { status: 204 }));

    if (url.pathname === "/status" || url.pathname === "/") return handleStatus(env, ctx);

    if (url.pathname === "/restart") {
      if (request.method !== "POST") return cors(json({ error: "method not allowed" }, 405));
      return handleRestart(request, env, ctx);
    }

    return cors(json({ error: "not found" }, 404));
  },
};

// ===== /status =====

async function handleStatus(env, ctx) {
  const cache = caches.default;
  const cacheKey = new Request("https://gdc-status/__status", { method: "GET" });
  const cached = await cache.match(cacheKey);
  if (cached) return cors(cached);

  let payload;
  try {
    const res = await panelGet(env, "api/instance");
    const body = await res.json();
    payload = clean(body, res.status);
  } catch (e) {
    return cors(json({ online: false, state: "unknown", error: "panel_unreachable", ts: Date.now() }, 200));
  }

  const ttl = payload.error ? 1 : STATUS_TTL_SECONDS;
  const response = json(payload, 200, { "Cache-Control": `public, max-age=${ttl}` });
  ctx.waitUntil(cache.put(cacheKey, response.clone()));
  return cors(response);
}

function clean(panelJson, httpStatus) {
  const apiStatus = panelJson && typeof panelJson.status === "number" ? panelJson.status : httpStatus;
  const data = panelJson && panelJson.data;

  if (!data || typeof data !== "object" || typeof data.status !== "number") {
    let detail = null;
    if (typeof data === "string") detail = data.slice(0, 80);
    else if (panelJson && typeof panelJson.data === "string") detail = panelJson.data.slice(0, 80);
    return {
      online: false, state: "unknown",
      error: apiStatus === 403 ? "panel_auth" : "panel_bad_response",
      panelStatus: apiStatus, detail,
      players: { current: null, max: null }, version: null, latency: null, ts: Date.now(),
    };
  }

  const info = data.info || {};
  const code = data.status;
  return {
    online: code === 3 && info.mcPingOnline === true,
    state: mapState(code),
    players: { current: numOrNull(info.currentPlayers), max: numOrNull(info.maxPlayers) },
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

// ===== /restart =====

async function handleRestart(request, env, ctx) {
  const auth = request.headers.get("Authorization") || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!env.RESTART_TOKEN || token !== env.RESTART_TOKEN) {
    return cors(json({ error: "unauthorized" }, 401));
  }

  const preset = (new URL(request.url).searchParams.get("preset") || "noupdate").toLowerCase();

  if (preset === "update") {
    // sequenza lunga in background: rispondo subito, il chiamante verra' fermato dallo stop
    ctx.waitUntil(runUpdateFlow(env).catch((e) => console.log("[gdc-update] errore:", (e && e.stack) || e)));
    return cors(json({ ok: true, mode: "update", note: "stop->update->start avviato in background" }, 202));
  }

  // noupdate: restart singolo
  const path = env.RESTART_PATH || "api/protected_instance/restart";
  try {
    const res = await panelGet(env, path);
    const body = await res.json().catch(() => ({}));
    const ok = res.ok && (body.status === 200 || body.data === true || body.data === undefined);
    return cors(json({ ok, mode: "noupdate", status: body.status ?? res.status }, ok ? 200 : 502));
  } catch (e) {
    return cors(json({ ok: false, error: "panel_unreachable" }, 502));
  }
}

// stop -> attende stopped -> update task -> attende (busy -> stopped) -> start
async function runUpdateFlow(env) {
  const POLL_MS = intEnv(env, "UPDATE_POLL_MS", 4000);
  const STOP_CAP = intEnv(env, "UPDATE_STOP_CAP", 20);   // ~80s per confermare stopped
  const BUSY_CAP = intEnv(env, "UPDATE_BUSY_CAP", 12);   // ~48s per vedere il busy partire
  const DONE_CAP = intEnv(env, "UPDATE_DONE_CAP", 90);   // ~6min per la fine dell'update
  const log = (...a) => console.log("[gdc-update]", ...a);
  let stopped = false;
  try {
    log("1) stop");
    await panelGet(env, "api/protected_instance/stop");
    stopped = await waitForStatus(env, (s) => s === 0, STOP_CAP, POLL_MS);
    log("stopped?", stopped);

    log("2) update task (sh ./update.sh)");
    await panelPost(env, "api/protected_instance/asynchronous", { task_name: "update" });

    const sawBusy = await waitForStatus(env, (s) => s === -1, BUSY_CAP, POLL_MS);
    if (sawBusy) {
      log("update in corso (busy), attendo la fine");
      await waitForStatus(env, (s) => s === 0, DONE_CAP, POLL_MS);
    } else {
      log("nessun busy rilevato (update rapido), piccola grace + verifica stopped");
      await sleep(POLL_MS);
      await waitForStatus(env, (s) => s === 0, 6, POLL_MS);
    }

    log("3) start");
    await panelGet(env, "api/protected_instance/open");
    log("sequenza update completata");
  } catch (e) {
    log("eccezione, tento comunque lo start per non lasciare il server giu':", (e && e.message) || e);
    try { await panelGet(env, "api/protected_instance/open"); } catch (_) {}
  }
}

async function waitForStatus(env, pred, cap, pollMs) {
  for (let i = 0; i < cap; i++) {
    try {
      const res = await panelGet(env, "api/instance");
      const body = await res.json();
      const s = body && body.data && typeof body.data.status === "number" ? body.data.status : null;
      if (s !== null && pred(s)) return true;
    } catch (_) { /* ignora e ritenta */ }
    await sleep(pollMs);
  }
  return false;
}

// ===== helpers =====

function panelGet(env, path, extra) {
  return fetch(panelUrl(env, path, extra), { headers: { Accept: "application/json" }, cf: { cacheTtl: 0 } });
}
function panelPost(env, path, extra) {
  return fetch(panelUrl(env, path, extra), { method: "POST", headers: { Accept: "application/json" }, cf: { cacheTtl: 0 } });
}

function panelUrl(env, path, extra) {
  const base = (env.PANEL_BASE || "").replace(/\/+$/, "");
  const p = String(path).replace(/^\/+/, "");
  const u = new URL(`${base}/${p}`);
  u.searchParams.set("apikey", env.API_KEY || "");
  u.searchParams.set("daemonId", env.DAEMON_ID || "");
  u.searchParams.set("uuid", env.INSTANCE_UUID || "");
  if (extra) for (const k of Object.keys(extra)) u.searchParams.set(k, extra[k]);
  return u.toString();
}

function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }
function intEnv(env, k, def) { const v = parseInt(env[k], 10); return Number.isFinite(v) ? v : def; }
function numOrNull(v) { return typeof v === "number" ? v : null; }

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
