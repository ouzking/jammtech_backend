// GET|POST /functions/v1/sos-track
// Suivi d'un SOS ou d'un TRAJET par un proche SANS l'app, via le lien reçu par
// SMS. La page web statique (web/track) lit le jeton dans le fragment de l'URL
// et appelle cette fonction toutes les 10 s.
//
// POST { t: string }  (ou GET ?t=…)
// Réponse 200, SOS : { kind: "sos", status: "active", name, started_at, silent, trail: [...] }
//                    ou { kind: "sos", status: "resolved" | "cancelled", name, resolved_at }
//        trajet   : { kind: "trip", status, name, mode, destination_label, destination,
//                     expected_arrival_at, vehicle_plate, vehicle_note, vehicle_photo_url, last_battery, trail }
//                    ou { kind: "trip", status: "arrived" | …, name, ended_at }
// Plus aucune position une fois l'alerte ou le trajet terminé. 404 : lien invalide ou expiré.
import { handler, HttpError, json, readJson } from "../_shared/http.ts";
import { env } from "../_shared/env.ts";
import { adminClient, rpc } from "../_shared/supabase.ts";
import { verifyAnyTrackToken } from "../_shared/track-token.ts";

Deno.serve(handler(["GET", "POST"], async (req) => {
  let token = "";
  if (req.method === "GET") {
    token = new URL(req.url).searchParams.get("t") ?? "";
  } else {
    const body = await readJson(req) as { t?: unknown };
    token = typeof body?.t === "string" ? body.t : "";
  }
  const claims = await verifyAnyTrackToken(env("TRACK_TOKEN_SECRET"), token);
  if (!claims) throw new HttpError(404, "invalid_link", "Lien de suivi invalide ou expiré");

  if (claims.kind === "sos") {
    const data = await rpc<Record<string, unknown> | null>("svc_sos_track", {
      p_event_id: claims.id,
      p_contact_id: claims.contactId,
    });
    if (!data) throw new HttpError(404, "invalid_link", "Lien de suivi invalide ou expiré");
    return json(req, { kind: "sos", ...data }, 200, { "Referrer-Policy": "no-referrer" });
  }

  const data = await rpc<Record<string, unknown> | null>("svc_trip_track", {
    p_trip_id: claims.id,
    p_contact_id: claims.contactId,
  });
  if (!data) throw new HttpError(404, "invalid_link", "Lien de suivi invalide ou expiré");
  const { vehicle_photo_path, ...rest } = data as { vehicle_photo_path?: string | null };
  let vehicle_photo_url: string | null = null;
  if (vehicle_photo_path) {
    const { data: signed } = await adminClient().storage.from("vehicle-photos").createSignedUrl(
      vehicle_photo_path,
      300,
    );
    vehicle_photo_url = signed?.signedUrl ?? null;
  }
  return json(req, { ...rest, vehicle_photo_url }, 200, { "Referrer-Policy": "no-referrer" });
}));
