// POST /functions/v1/trip-watchdog   (interne : en-tête x-cron-secret)
// Envoie les notifications de trajet en attente : « Tout va bien ? », retard,
// batterie faible, arrivée automatique… et ESCALADE EN SOS quand le voyageur
// ne répond pas. Appelée par pg_cron chaque minute (après la surveillance SQL)
// et réveillée immédiatement par pg_net à chaque nouvel événement.
//
// Corps : { dispatch?: true, tick?: true, trip_id?: uuid }
//   tick : lance d'abord un tour de surveillance (utile hors pg_cron, ex. tests).
import { handler, json, readJson } from "../_shared/http.ts";
import { requireInternal, rpc } from "../_shared/supabase.ts";
import { dispatchTripEvents } from "../_shared/trip.ts";
import { parse, uuid, z } from "../_shared/validation.ts";

const Body = z.object({
  dispatch: z.boolean().optional(),
  tick: z.boolean().optional(),
  trip_id: uuid.optional(),
}).strict();

Deno.serve(handler(["POST"], async (req) => {
  requireInternal(req);
  const body = parse(Body, await readJson(req));
  const actions = body.tick ? await rpc<number>("svc_trip_watchdog_tick", {}) : 0;
  const processed = await dispatchTripEvents(body.trip_id ?? null);
  return json(req, { actions, processed });
}));
