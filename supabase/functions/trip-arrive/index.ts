// POST /functions/v1/trip-arrive
// « Je suis arrivé·e » : clôt le trajet et prévient les proches (« Arrivé·e à
// 20 h 14 »). L'arrivée est aussi détectée automatiquement par le serveur à
// moins de 150 m de la destination (push_location).
//
// Corps : { trip_id: uuid }
// Réponse 200 : le trajet clos.   404 : aucun trajet en cours.
import { handler, HttpError, json, readJson } from "../_shared/http.ts";
import { errors } from "../_shared/messages.ts";
import { requireUser, rpc } from "../_shared/supabase.ts";
import { dispatchTripEvents } from "../_shared/trip.ts";
import { parse, uuid, z } from "../_shared/validation.ts";

const Body = z.object({ trip_id: uuid }).strict();

Deno.serve(handler(["POST"], async (req) => {
  const user = await requireUser(req);
  const body = parse(Body, await readJson(req));
  const trip = await rpc<Record<string, unknown> | null>("svc_trip_arrive", {
    p_user_id: user.id,
    p_trip_id: body.trip_id,
  });
  if (!trip) throw new HttpError(404, "not_found", errors.noActiveTrip);
  await dispatchTripEvents(body.trip_id).catch((e) => console.error("trip_arrive_dispatch_failed", String(e)));
  return json(req, trip);
}));
