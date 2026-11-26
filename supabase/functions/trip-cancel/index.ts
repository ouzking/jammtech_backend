// POST /functions/v1/trip-cancel
// Annule un trajet en cours. Les proches ne sont prévenus que si le trajet
// avait réellement commencé (plus de 2 minutes).
//
// Corps : { trip_id: uuid }
// Réponse 200 : le trajet annulé + { watchers_notified }.   404 : aucun trajet en cours.
import { handler, HttpError, json, readJson } from "../_shared/http.ts";
import { errors } from "../_shared/messages.ts";
import { requireUser, rpc } from "../_shared/supabase.ts";
import { dispatchTripEvents } from "../_shared/trip.ts";
import { parse, uuid, z } from "../_shared/validation.ts";

const Body = z.object({ trip_id: uuid }).strict();

Deno.serve(handler(["POST"], async (req) => {
  const user = await requireUser(req);
  const body = parse(Body, await readJson(req));
  const trip = await rpc<Record<string, unknown> | null>("svc_trip_cancel", {
    p_user_id: user.id,
    p_trip_id: body.trip_id,
  });
  if (!trip) throw new HttpError(404, "not_found", errors.noActiveTrip);
  if (trip.watchers_notified) {
    await dispatchTripEvents(body.trip_id).catch((e) => console.error("trip_cancel_dispatch_failed", String(e)));
  }
  return json(req, trip);
}));
