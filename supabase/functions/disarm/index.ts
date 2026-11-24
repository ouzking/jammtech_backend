// POST /functions/v1/disarm
// Désarme une maison après vérification du code de désarmement.
//
// CODE DE CONTRAINTE : s'il est saisi, la réponse est STRICTEMENT identique à
// un désarmement réussi (même corps, même statut, même temps de réponse : les
// deux comparaisons bcrypt sont toujours faites et l'alerte part en tâche de
// fond). Un SOS silencieux est déclenché ; rien n'apparaît sur l'appareil.
//
// Corps : { home_id: uuid, code?: string, client_device?: string,
//           lat?: number, lng?: number, accuracy_m?: number }
// L'app DOIT toujours envoyer sa position si elle l'a (sinon un envoi
// conditionnel trahirait la contrainte).
// Réponse 200 : { home_id, arm_mode: "disarmed", arm_mode_changed_at, warnings: [] }
import { handler, HttpError, json, readJson, runInBackground } from "../_shared/http.ts";
import { errors } from "../_shared/messages.ts";
import { startAndDispatchSos } from "../_shared/sos.ts";
import { requireUser, rpc } from "../_shared/supabase.ts";
import { accuracy, lat, lng, parse, uuid, z } from "../_shared/validation.ts";

const Body = z.object({
  home_id: uuid,
  code: z.string().max(16).optional(),
  client_device: z.string().max(120).optional(),
  lat: lat.optional(),
  lng: lng.optional(),
  accuracy_m: accuracy.optional(),
}).strict();

Deno.serve(handler(["POST"], async (req) => {
  const user = await requireUser(req);
  const body = parse(Body, await readJson(req));

  const check = await rpc<string>("svc_verify_disarm_code", { p_user_id: user.id, p_code: body.code ?? null });
  if (check === "locked") throw new HttpError(429, "locked", errors.locked);
  if (check === "invalid") throw new HttpError(401, "invalid_code", errors.invalidCode);

  const home = await rpc<Record<string, unknown> | null>("svc_disarm_home", {
    p_home_id: body.home_id,
    p_user_id: user.id,
    p_client_device: body.client_device ?? null,
  });
  if (!home) throw new HttpError(404, "not_found", errors.homeNotFound);

  if (check === "duress") {
    runInBackground(startAndDispatchSos({
      userId: user.id,
      clientKey: crypto.randomUUID(),
      trigger: "duress_code",
      silent: true,
      lat: body.lat,
      lng: body.lng,
      accuracy: body.accuracy_m,
    }));
  }

  return json(req, home);
}));
