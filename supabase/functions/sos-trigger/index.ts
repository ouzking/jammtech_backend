// POST /functions/v1/sos-trigger
// Déclenche un SOS déjà CONFIRMÉ par l'app (appui 3 s + compte à rebours 5 s).
// Idempotent : `client_key` (UUID généré par l'app au moment de la
// confirmation) garantit qu'un nouvel essai réseau ne renvoie rien en double.
//
// Corps : { client_key: uuid, lat?: number, lng?: number, accuracy_m?: number }
// Réponse 200 : { sos_event_id, status, started_at, created, location_shared,
//                notified: { push, sms, failed } }
import { handler, json, readJson } from "../_shared/http.ts";
import { startAndDispatchSos } from "../_shared/sos.ts";
import { requireUser } from "../_shared/supabase.ts";
import { accuracy, lat, lng, parse, uuid, z } from "../_shared/validation.ts";

const Body = z.object({
  client_key: uuid,
  lat: lat.optional(),
  lng: lng.optional(),
  accuracy_m: accuracy.optional(),
}).strict();

Deno.serve(handler(["POST"], async (req) => {
  const t0 = performance.now();
  const user = await requireUser(req);
  const body = parse(Body, await readJson(req));

  const { result, updates } = await startAndDispatchSos({
    userId: user.id,
    clientKey: body.client_key,
    trigger: "button",
    silent: false,
    lat: body.lat,
    lng: body.lng,
    accuracy: body.accuracy_m,
  });

  const sentPush = updates.filter((u) => u.status === "sent" && u.provider === "fcm").length;
  const sentSms = updates.filter((u) => u.status === "sent" && u.provider !== "fcm").length;
  const failed = updates.filter((u) => u.status === "failed").length;
  // Aucune donnée personnelle ni position dans les journaux.
  console.log(
    "sos_trigger",
    JSON.stringify({
      created: result.created,
      recipients: result.recipients.length,
      sent_push: sentPush,
      sent_sms: sentSms,
      failed,
      ms: Math.round(performance.now() - t0),
    }),
  );

  return json(req, {
    sos_event_id: result.event.id,
    status: result.event.status,
    started_at: result.event.started_at,
    created: result.created,
    location_shared: result.location_shared,
    notified: { push: sentPush, sms: sentSms, failed },
  });
}));
