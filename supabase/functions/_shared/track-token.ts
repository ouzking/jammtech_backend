// Jetons de suivi SOS pour les proches sans l'app (lien SMS).
// Format compact (≈ 70 caractères) pour limiter la taille du SMS :
//   base64url( event_id[16] | contact_id[16] | exp[4] | hmac_sha256[0..16] )
// Le jeton est placé dans le FRAGMENT de l'URL (#…) : il n'apparaît pas dans
// les journaux des serveurs web. Sans état : la révocation est assurée par le
// statut du SOS (aucune position renvoyée une fois clos) et l'expiration.

const enc = new TextEncoder();

function uuidToBytes(u: string): Uint8Array<ArrayBuffer> {
  const hex = u.replace(/-/g, "");
  if (!/^[0-9a-f]{32}$/i.test(hex)) throw new Error("uuid invalide");
  return Uint8Array.from(hex.match(/../g)!.map((h) => parseInt(h, 16)));
}

function bytesToUuid(b: Uint8Array): string {
  const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

function b64url(b: Uint8Array): string {
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromB64url(s: string): Uint8Array<ArrayBuffer> {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  return Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + pad), (c) => c.charCodeAt(0));
}

async function hmac(secret: string, data: Uint8Array<ArrayBuffer>): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
    "sign",
  ]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, data));
}

export async function createTrackToken(
  secret: string,
  eventId: string,
  contactId: string,
  ttlSeconds = 72 * 3600,
  now = Date.now(),
): Promise<string> {
  const exp = Math.floor(now / 1000) + ttlSeconds;
  const body = new Uint8Array(36);
  body.set(uuidToBytes(eventId), 0);
  body.set(uuidToBytes(contactId), 16);
  new DataView(body.buffer).setUint32(32, exp);
  const sig = (await hmac(secret, body)).slice(0, 16);
  const out = new Uint8Array(52);
  out.set(body, 0);
  out.set(sig, 36);
  return b64url(out);
}

export async function verifyTrackToken(
  secret: string,
  token: string,
  now = Date.now(),
): Promise<{ eventId: string; contactId: string; exp: number } | null> {
  if (!/^[A-Za-z0-9_-]{60,80}$/.test(token)) return null;
  let raw: Uint8Array<ArrayBuffer>;
  try {
    raw = fromB64url(token);
  } catch {
    return null;
  }
  if (raw.length !== 52) return null;
  const body = raw.slice(0, 36);
  const sig = raw.slice(36);
  const expected = (await hmac(secret, body)).slice(0, 16);
  let diff = 0;
  for (let i = 0; i < 16; i++) diff |= sig[i] ^ expected[i];
  if (diff !== 0) return null;
  const exp = new DataView(body.buffer).getUint32(32);
  if (exp * 1000 < now) return null;
  return { eventId: bytesToUuid(body.slice(0, 16)), contactId: bytesToUuid(body.slice(16, 32)), exp };
}

// Liens de suivi d'un TRAJET : même format, clé dérivée distincte, de sorte
// qu'un jeton de trajet ne puisse jamais ouvrir un SOS (et inversement).
const tripKey = (secret: string) => `${secret}:trip`;

export function createTripTrackToken(secret: string, tripId: string, contactId: string, ttlSeconds = 26 * 3600) {
  return createTrackToken(tripKey(secret), tripId, contactId, ttlSeconds);
}

export async function verifyAnyTrackToken(
  secret: string,
  token: string,
  now = Date.now(),
): Promise<{ kind: "sos" | "trip"; id: string; contactId: string } | null> {
  const sos = await verifyTrackToken(secret, token, now);
  if (sos) return { kind: "sos", id: sos.eventId, contactId: sos.contactId };
  const trip = await verifyTrackToken(tripKey(secret), token, now);
  if (trip) return { kind: "trip", id: trip.eventId, contactId: trip.contactId };
  return null;
}
