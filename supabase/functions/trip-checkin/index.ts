// POST /functions/v1/trip-checkin
// Réponse au « Tout va bien ? » d'un trajet.
//
// CODE DE CONTRAINTE : accepté comme le code personnel, avec une réponse
// STRICTEMENT identique (statut, corps, temps : deux comparaisons bcrypt
// systématiques, SOS envoyé en tâche de fond). Il déclenche un SOS silencieux ;
// le trajet reste dans le même état visible que pour un « oui » normal.
//
// Corps : { trip_id: uuid, code?: string, lat?: number, lng?: number }
//   (code facultatif si l'utilisateur n'a pas défini de code de désarmement)
// Réponse 200 : { ok: true, trip_id, next_check_after }
// 401 code incorrect · 429 trop d'essais · 404 aucun trajet en cours
import { handler, HttpError, json, readJson, runInBackground } from "../_shared/http.ts";
import { errors } from "../_shared/messages.ts";
import { startAndDispatchSos } from "../_shared/sos.ts";
import { requireUser, rpc } from "../_shared/supabase.ts";
import { lat, lng, parse, uuid, z } from "../_shared/validation.ts";

const Body = z.object({
  trip_id: uuid,
  code: z.string().max(16).optional(),
  lat: lat.optional(),
  lng: lng.optional(),
}).strict();

Deno.serve(handler(["POST"], async (req) => {
  const user = await requireUser(req);
  const body = parse(Body, await readJson(req));

  const check = await rpc<string>("svc_verify_disarm_code", { p_user_id: user.id, p_code: body.code ?? null });
  if (check === "locked") throw new HttpError(429, "locked", errors.locked);
  if (check === "invalid") throw new HttpError(401, "invalid_code", errors.invalidCode);
  const duress = check === "duress";

  const res = await rpc<Record<string, unknown> | null>("svc_trip_checkin", {
    p_user_id: user.id,
    p_trip_id: body.trip_id,
    p_result: duress ? "duress" : "ok",
    p_lat: body.lat ?? null,
    p_lng: body.lng ?? null,
  });
  if (!res) throw new HttpError(404, "not_found", errors.noActiveTrip);

  if (duress) {
    runInBackground(startAndDispatchSos({
      userId: user.id,
      clientKey: crypto.randomUUID(),
      trigger: "duress_code",
      silent: true,
      lat: body.lat,
      lng: body.lng,
    }));
  }
  return json(req, res);
}));
