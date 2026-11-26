// POST /functions/v1/trip-start
// Démarre un trajet sécurisé. Idempotent via `client_key` : un nouvel essai
// réseau ne renvoie rien en double. Les proches choisis sont prévenus (push si
// app, sinon SMS avec lien de suivi) ; la position est ensuite envoyée par
// `push_location` comme d'habitude.
//
// Corps :
// { client_key: uuid, mode: "taxi"|"clando"|"moto"|"public"|"walk"|"car",
//   destination: { lat, lng, label }, origin?: { lat, lng, label? },
//   expected_arrival_at: ISO-8601 (futur, ≤ 24 h), grace_minutes?: 0..120,
//   checkin_first_minutes?: 1..15, checkin_second_minutes?: 1..15,
//   watcher_contact_ids?: uuid[] (défaut : tous les proches),
//   vehicle_plate?: string, vehicle_note?: string,
//   route?: [[lat, lng], …] (2 à 500 points), position?: { lat, lng, accuracy_m? } }
// Réponse 200 : { trip, created, watchers }   409 : un trajet est déjà en cours.
import { handler, HttpError, json, readJson } from "../_shared/http.ts";
import { errors } from "../_shared/messages.ts";
import { requireUser, rpc } from "../_shared/supabase.ts";
import { dispatchTripEvents } from "../_shared/trip.ts";
import { accuracy, lat, lng, parse, uuid, z } from "../_shared/validation.ts";

const Place = z.object({ lat, lng, label: z.string().trim().min(1).max(200) }).strict();

const Body = z.object({
  client_key: uuid,
  mode: z.enum(["taxi", "clando", "moto", "public", "walk", "car"]),
  destination: Place,
  origin: z.object({ lat, lng, label: z.string().trim().max(200).optional() }).strict().optional(),
  expected_arrival_at: z.string().datetime({ offset: true }),
  grace_minutes: z.number().int().min(0).max(120).optional(),
  checkin_first_minutes: z.number().int().min(1).max(15).optional(),
  checkin_second_minutes: z.number().int().min(1).max(15).optional(),
  watcher_contact_ids: z.array(uuid).max(5).optional(),
  vehicle_plate: z.string().trim().max(20).regex(/^[A-Za-z0-9 -]*$/).optional(),
  vehicle_note: z.string().trim().max(200).optional(),
  route: z.array(z.tuple([lat, lng])).min(2).max(500).optional(),
  position: z.object({ lat, lng, accuracy_m: accuracy.optional() }).strict().optional(),
}).strict().refine((b) => {
  const eta = Date.parse(b.expected_arrival_at);
  return eta > Date.now() && eta < Date.now() + 24 * 3600_000;
}, { message: "L'heure d'arrivée doit être dans les 24 prochaines heures", path: ["expected_arrival_at"] });

Deno.serve(handler(["POST"], async (req) => {
  const user = await requireUser(req);
  const body = parse(Body, await readJson(req));
  const { client_key, ...input } = body;

  const result = await rpc<Record<string, unknown>>("svc_trip_start", {
    p_user_id: user.id,
    p_client_key: client_key,
    p_input: input,
  });
  if (result.error === "trip_already_active") {
    throw new HttpError(409, "trip_already_active", errors.tripAlreadyActive, { trip_id: result.trip_id });
  }

  const trip = result.trip as { id: string };
  // Envoi immédiat des notifications de démarrage (rattrapées par pg_cron sinon).
  await dispatchTripEvents(trip.id).catch((e) => console.error("trip_start_dispatch_failed", String(e)));
  console.log("trip_start", JSON.stringify({ created: result.created, watchers: result.watchers }));
  return json(req, result);
}));
