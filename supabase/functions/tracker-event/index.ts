// POST /functions/v1/tracker-event
// Ingestion générique des traceurs GPS de véhicules (passerelles Teltonika,
// Concox/Jimi ou autres, converties en ce format). AUCUNE commande à distance.
//
// En-tête : Authorization: Bearer <tracker_id>.<secret>  (obtenu via register_tracker)
// Corps :
// { event_id: string (unique par traceur, idempotence),
//   type: "position" | "heartbeat" | "ignition" | "power" | "battery" | "shock",
//   occurred_at?: ISO-8601,
//   positions?: [{ lat, lng, speed_kmh?, heading?, ignition?, recorded_at? }] (1 à 100),
//   ignition?: boolean, external_power?: boolean, battery?: 0..100 }
// Alertes : traceur débranché, choc, contact moteur la nuit, mouvement hors des
// heures autorisées, sortie de zone (géorepérage).
import { handler, HttpError, json, readJson, runInBackground } from "../_shared/http.ts";
import { notifyAlert } from "../_shared/notify.ts";
import { adminClient, rpc } from "../_shared/supabase.ts";
import { parse, uuid, z } from "../_shared/validation.ts";
import { evaluateTrackerAlerts, type Geofence, type VehicleRules } from "../_shared/vehicle.ts";

const Position = z.object({
  lat: z.number().finite().min(-90).max(90),
  lng: z.number().finite().min(-180).max(180),
  speed_kmh: z.number().finite().min(0).max(400).optional(),
  heading: z.number().finite().min(0).max(360).optional(),
  ignition: z.boolean().optional(),
  recorded_at: z.string().datetime({ offset: true }).optional(),
}).strict();

const Body = z.object({
  event_id: z.string().min(1).max(128),
  type: z.enum(["position", "heartbeat", "ignition", "power", "battery", "shock"]),
  occurred_at: z.string().datetime({ offset: true }).optional(),
  positions: z.array(Position).min(1).max(100).optional(),
  ignition: z.boolean().optional(),
  external_power: z.boolean().optional(),
  battery: z.number().int().min(0).max(100).optional(),
}).strict();

interface TrackerCtx {
  tracker: {
    id: string;
    vehicle_id: string;
    name: string;
    ignition: boolean | null;
    external_power: boolean | null;
    inside_geofence: boolean | null;
  };
  vehicle: { id: string; plate: string | null; brand_model: string | null };
  rules: VehicleRules | null;
  geofences: Geofence[];
}

Deno.serve(handler(["POST"], async (req) => {
  const header = req.headers.get("authorization") ?? "";
  const [id, secret] = (header.startsWith("Bearer ") ? header.slice(7).trim() : "").split(".");
  if (!uuid.safeParse(id).success || !/^[0-9a-f]{64}$/.test(secret ?? "")) {
    throw new HttpError(401, "unauthorized", "Jeton de traceur invalide");
  }
  const ctx = await rpc<TrackerCtx | null>("svc_authenticate_tracker", { p_tracker_id: id, p_secret: secret });
  if (!ctx) throw new HttpError(401, "unauthorized", "Jeton de traceur invalide");

  const body = parse(Body, await readJson(req));
  const db = adminClient();

  const { error: dupErr } = await db.from("tracker_events").insert({
    tracker_id: ctx.tracker.id,
    external_id: body.event_id,
    type: body.type,
    payload: body,
  });
  if (dupErr) {
    if (dupErr.code === "23505") return json(req, { ok: true, duplicate: true });
    throw new HttpError(500, "database_error", "Erreur de base de données");
  }

  const now = new Date();
  const positions = body.positions ?? [];
  if (positions.length) {
    const { error } = await db.from("tracker_positions").insert(positions.map((p) => ({
      tracker_id: ctx.tracker.id,
      vehicle_id: ctx.tracker.vehicle_id,
      lat: p.lat,
      lng: p.lng,
      speed_kmh: p.speed_kmh ?? null,
      heading: p.heading ?? null,
      ignition: p.ignition ?? body.ignition ?? null,
      recorded_at: p.recorded_at ?? body.occurred_at ?? now.toISOString(),
    })));
    if (error) throw new HttpError(500, "database_error", "Erreur de base de données");
  }
  const last = positions[positions.length - 1];
  const ignition = body.ignition ?? last?.ignition;

  const label = [ctx.vehicle.brand_model, ctx.vehicle.plate].filter(Boolean).join(" ") || "votre véhicule";
  const { alerts, insideGeofence } = evaluateTrackerAlerts({
    trackerId: ctx.tracker.id,
    vehicleLabel: label,
    previous: ctx.tracker,
    update: {
      type: body.type,
      lat: last?.lat,
      lng: last?.lng,
      speed_kmh: last?.speed_kmh,
      ignition,
      external_power: body.external_power,
    },
    rules: ctx.rules,
    geofences: ctx.geofences,
  }, now);

  const patch: Record<string, unknown> = { is_online: true, last_seen_at: now.toISOString() };
  if (last) Object.assign(patch, { last_lat: last.lat, last_lng: last.lng, last_speed_kmh: last.speed_kmh ?? null });
  if (ignition !== undefined) patch.ignition = ignition;
  if (body.external_power !== undefined) patch.external_power = body.external_power;
  if (body.battery !== undefined) patch.battery_level = body.battery;
  if (insideGeofence !== ctx.tracker.inside_geofence) patch.inside_geofence = insideGeofence;
  await db.from("trackers").update(patch).eq("id", ctx.tracker.id);

  // Retour en ligne : l'alerte « hors ligne » ouverte est close.
  await db.from("security_alerts").update({ resolved_at: now.toISOString() })
    .eq("dedupe_key", `tracker_offline:${ctx.tracker.id}`).is("resolved_at", null);

  const alertIds: string[] = [];
  for (const a of alerts) {
    const alertId = await rpc<string | null>("svc_create_vehicle_alert", {
      p_vehicle_id: ctx.tracker.vehicle_id,
      p_severity: a.severity,
      p_title: a.title,
      p_description: a.description,
      p_dedupe_key: a.dedupe,
      p_lat: last?.lat ?? null,
      p_lng: last?.lng ?? null,
    });
    if (alertId) {
      alertIds.push(alertId);
      runInBackground(notifyAlert(alertId));
    }
  }
  return json(req, { ok: true, alerts: alertIds });
}));
