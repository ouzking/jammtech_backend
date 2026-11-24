// GET|POST /functions/v1/sos-track
// Suivi d'un SOS par un proche SANS l'app, via le lien reçu par SMS.
// La page web statique (web/track) lit le jeton dans le fragment de l'URL et
// appelle cette fonction toutes les 10 s.
//
// POST { t: string }  (ou GET ?t=…)
// Réponse 200 : { status: "active", name, started_at, silent, trail: [{lat,lng,accuracy_m,recorded_at}] }
//            ou { status: "resolved" | "cancelled", name, resolved_at }  (plus aucune position)
// 404 : lien invalide ou expiré.
import { handler, HttpError, json, readJson } from "../_shared/http.ts";
import { env } from "../_shared/env.ts";
import { rpc } from "../_shared/supabase.ts";
import { verifyTrackToken } from "../_shared/track-token.ts";

Deno.serve(handler(["GET", "POST"], async (req) => {
  let token = "";
  if (req.method === "GET") {
    token = new URL(req.url).searchParams.get("t") ?? "";
  } else {
    const body = await readJson(req) as { t?: unknown };
    token = typeof body?.t === "string" ? body.t : "";
  }
  const claims = await verifyTrackToken(env("TRACK_TOKEN_SECRET"), token);
  if (!claims) throw new HttpError(404, "invalid_link", "Lien de suivi invalide ou expiré");

  const data = await rpc<Record<string, unknown> | null>("svc_sos_track", {
    p_event_id: claims.eventId,
    p_contact_id: claims.contactId,
  });
  if (!data) throw new HttpError(404, "invalid_link", "Lien de suivi invalide ou expiré");
  return json(req, data, 200, { "Referrer-Policy": "no-referrer" });
}));
