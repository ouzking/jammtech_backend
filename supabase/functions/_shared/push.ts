// Notifications push via Firebase Cloud Messaging (API HTTP v1).
// Android natif, iOS via APNs (configuré dans la console Firebase).
//
// Secret : FCM_SERVICE_ACCOUNT = JSON du compte de service (brut ou base64).
import { optionalEnv } from "./env.ts";

export interface PushTarget {
  token: string;
  platform: "android" | "ios" | "web";
}

export interface PushMessage {
  title?: string;
  body?: string;
  data?: Record<string, string>;
  /** Alerte urgente (SOS, critique) : priorité max, son, contourne le mode silencieux si possible. */
  urgent?: boolean;
  sound?: boolean;
  /** Message de données uniquement, sans affichage (ex. suivi discret). */
  silent?: boolean;
  channelId?: string;
}

export interface PushResult {
  ok: boolean;
  token: string;
  messageId?: string;
  error?: string;
  /** Token invalide (désinstallation) : à supprimer. */
  unregistered?: boolean;
}

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

let cachedAccount: ServiceAccount | null = null;
let cachedToken: { value: string; exp: number } | null = null;

function serviceAccount(): ServiceAccount | null {
  if (cachedAccount) return cachedAccount;
  const raw = optionalEnv("FCM_SERVICE_ACCOUNT");
  if (!raw) return null;
  const text = raw.trim().startsWith("{") ? raw : atob(raw);
  cachedAccount = JSON.parse(text);
  return cachedAccount;
}

function b64url(data: ArrayBuffer | Uint8Array | string): string {
  const bytes = typeof data === "string"
    ? new TextEncoder().encode(data)
    : data instanceof Uint8Array
    ? data
    : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function accessToken(sa: ServiceAccount, f: typeof fetch): Promise<string> {
  if (cachedToken && cachedToken.exp > Date.now() + 60_000) return cachedToken.value;
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const now = Math.floor(Date.now() / 1000);
  const tokenUri = sa.token_uri ?? "https://oauth2.googleapis.com/token";
  const unsigned = `${b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }))}.${
    b64url(JSON.stringify({
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      aud: tokenUri,
      iat: now,
      exp: now + 3600,
    }))
  }`;
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  const res = await f(tokenUri, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${unsigned}.${b64url(sig)}`,
    }),
  });
  const data = await res.json();
  if (!res.ok || !data.access_token) throw new Error(`fcm_oauth_${res.status}`);
  cachedToken = { value: data.access_token, exp: Date.now() + Number(data.expires_in ?? 3600) * 1000 };
  return cachedToken.value;
}

export function buildFcmMessage(target: PushTarget, msg: PushMessage): Record<string, unknown> {
  const data = Object.fromEntries(Object.entries(msg.data ?? {}).map(([k, v]) => [k, String(v)]));
  if (msg.silent) {
    return {
      token: target.token,
      data,
      android: { priority: "HIGH" },
      apns: {
        headers: { "apns-priority": "5", "apns-push-type": "background" },
        payload: { aps: { "content-available": 1 } },
      },
    };
  }
  const sound = msg.sound !== false;
  return {
    token: target.token,
    notification: { title: msg.title, body: msg.body },
    data,
    android: {
      priority: "HIGH",
      notification: {
        channel_id: msg.channelId ?? (msg.urgent ? "sos" : "alerts"),
        sound: sound ? "default" : undefined,
        default_vibrate_timings: sound,
        notification_priority: msg.urgent ? "PRIORITY_MAX" : "PRIORITY_HIGH",
        visibility: msg.urgent ? "PUBLIC" : "PRIVATE",
      },
    },
    apns: {
      headers: { "apns-priority": "10", "apns-push-type": "alert" },
      payload: {
        aps: {
          sound: sound ? "default" : undefined,
          "interruption-level": msg.urgent ? "time-sensitive" : "active",
        },
      },
    },
  };
}

export async function sendPush(
  target: PushTarget,
  msg: PushMessage,
  opts: { fetch?: typeof fetch; timeoutMs?: number } = {},
): Promise<PushResult> {
  const f = opts.fetch ?? fetch;
  const sa = serviceAccount();
  if (!sa) {
    console.log("push_console", target.platform, msg.title ?? "(données)");
    return { ok: true, token: target.token, messageId: "console" };
  }
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), opts.timeoutMs ?? 2500);
  try {
    const token = await accessToken(sa, f);
    const res = await f(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ message: buildFcmMessage(target, msg) }),
      signal: ctrl.signal,
    });
    const data = await res.json().catch(() => ({}));
    if (res.ok) return { ok: true, token: target.token, messageId: data.name };
    const status: string = data?.error?.status ?? "";
    const unregistered = res.status === 404 || status === "NOT_FOUND" || status === "UNREGISTERED" ||
      JSON.stringify(data).includes("UNREGISTERED");
    return { ok: false, token: target.token, error: `${res.status} ${status}`.trim(), unregistered };
  } catch (e) {
    return { ok: false, token: target.token, error: ctrl.signal.aborted ? "timeout" : String(e) };
  } finally {
    clearTimeout(timer);
  }
}

/** Envoie à plusieurs appareils en parallèle ; ok si au moins un succès. */
export async function sendPushToAll(targets: PushTarget[], msg: PushMessage) {
  const results = await Promise.all(targets.map((t) => sendPush(t, msg)));
  return { ok: results.some((r) => r.ok), results };
}
