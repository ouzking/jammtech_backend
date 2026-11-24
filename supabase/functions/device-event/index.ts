// POST /functions/v1/device-event
// Ingestion générique des événements d'appareils (caméras, capteurs, sirène,
// serrure…), indépendante du fabricant. Une passerelle ou l'appareil appelle
// ce webhook avec son jeton d'ingestion (obtenu via la RPC register_device).
//
// En-tête : Authorization: Bearer <device_id>.<secret>
// Corps :
//   { event_id: string (unique par appareil, pour l'idempotence),
//     type: "heartbeat" | "motion" | "door" | "door_left_open" | "tamper"
//         | "recording" | "recording_uploaded" | "firmware" | "state",
//     occurred_at?: ISO-8601,
//     data?: { … selon le type } }
//
// Types :
//   heartbeat            { firmware_version?, is_on?, state? }      → en ligne
//   motion               {}                                         → alerte critique si armé « Absence »
//   door                 { open: boolean }                          → alerte si ouverture en mode armé
//   door_left_open       { minutes?: number }                       → avertissement
//   tamper               {}                                         → alerte critique
//   recording            { title?, duration_seconds, motion?, started_at?, with_thumbnail? }
//                         → crée l'enregistrement et renvoie des URL d'upload signées
//   recording_uploaded   { recording_id }                           → marque l'upload terminé
//   firmware             { version }                                → info « Mise à jour installée »
//   state                { is_on?, state? }                         → mise à jour d'état
import { handler, HttpError, json, readJson, runInBackground } from "../_shared/http.ts";
import { notifyAlert } from "../_shared/notify.ts";
import { adminClient, rpc } from "../_shared/supabase.ts";
import { parse, uuid, z } from "../_shared/validation.ts";

const Body = z.object({
  event_id: z.string().min(1).max(128),
  type: z.enum([
    "heartbeat",
    "motion",
    "door",
    "door_left_open",
    "tamper",
    "recording",
    "recording_uploaded",
    "firmware",
    "state",
  ]),
  occurred_at: z.string().datetime({ offset: true }).optional(),
  data: z.record(z.unknown()).default({}),
}).strict();

const RecordingData = z.object({
  title: z.string().min(1).max(120).optional(),
  duration_seconds: z.number().int().min(0).max(86400),
  motion: z.boolean().optional(),
  started_at: z.string().datetime({ offset: true }).optional(),
  with_thumbnail: z.boolean().optional(),
});

interface DeviceCtx {
  device_id: string;
  home_id: string;
  type: string;
  name: string;
  room: string | null;
  is_online: boolean;
}

async function authenticateDevice(req: Request): Promise<DeviceCtx> {
  const header = req.headers.get("authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  const [id, secret] = token.split(".");
  if (!uuid.safeParse(id).success || !/^[0-9a-f]{64}$/.test(secret ?? "")) {
    throw new HttpError(401, "unauthorized", "Jeton d'appareil invalide");
  }
  const dev = await rpc<DeviceCtx | null>("svc_authenticate_device", { p_device_id: id, p_secret: secret });
  if (!dev) throw new HttpError(401, "unauthorized", "Jeton d'appareil invalide");
  return dev;
}

Deno.serve(handler(["POST"], async (req) => {
  const dev = await authenticateDevice(req);
  const body = parse(Body, await readJson(req));
  const db = adminClient();

  // Idempotence : un même event_id n'est traité qu'une fois.
  const { error: dupErr } = await db.from("device_events").insert({
    device_id: dev.device_id,
    home_id: dev.home_id,
    external_id: body.event_id,
    type: body.type,
    payload: body.data,
  });
  if (dupErr) {
    if (dupErr.code === "23505") return json(req, { ok: true, duplicate: true });
    throw new HttpError(500, "database_error", "Erreur de base de données");
  }

  // Présence + état.
  const patch: Record<string, unknown> = { is_online: true, last_seen_at: new Date().toISOString() };
  const d = body.data as Record<string, unknown>;
  if (typeof d.firmware_version === "string") patch.firmware_version = d.firmware_version.slice(0, 50);
  if (body.type === "firmware" && typeof d.version === "string") patch.firmware_version = d.version.slice(0, 50);
  if (typeof d.is_on === "boolean") patch.is_on = d.is_on;
  if (body.type === "door" && typeof d.open === "boolean") patch.state = { open: d.open };
  if (d.state && typeof d.state === "object" && !Array.isArray(d.state)) patch.state = d.state;
  await db.from("devices").update(patch).eq("id", dev.device_id);

  // Retour en ligne : l'alerte « hors ligne » ouverte est close.
  if (!dev.is_online) {
    await db.from("security_alerts").update({ resolved_at: new Date().toISOString() })
      .eq("dedupe_key", `offline:${dev.device_id}`).is("resolved_at", null);
  }

  const { data: home } = await db.from("homes").select("arm_mode").eq("id", dev.home_id).single();
  const armed = home?.arm_mode && home.arm_mode !== "disarmed";
  const where = dev.room ?? dev.name;
  let alertId: string | null = null;
  let response: Record<string, unknown> = { ok: true };

  const createAlert = (
    category: string,
    severity: string,
    title: string,
    description: string,
    dedupe?: string,
    recordingId?: string,
  ) =>
    rpc<string | null>("svc_create_alert", {
      p_user_id: null,
      p_home_id: dev.home_id,
      p_category: category,
      p_severity: severity,
      p_title: title,
      p_description: description,
      p_location_label: where,
      p_device_id: dev.device_id,
      p_recording_id: recordingId ?? null,
      p_dedupe_key: dedupe ?? null,
    });

  switch (body.type) {
    case "motion":
      if (home?.arm_mode === "away") {
        alertId = await createAlert(
          "intrusion",
          "critical",
          "Intrusion détectée",
          `Mouvement détecté par ${dev.name} alors que le système était armé.`,
        );
      }
      break;
    case "door":
      if (d.open === true && armed) {
        alertId = await createAlert(
          "intrusion",
          home?.arm_mode === "away" ? "critical" : "warning",
          "Ouverture détectée",
          `${dev.name} a été ouvert(e) alors que le système était armé.`,
        );
      }
      break;
    case "door_left_open":
      alertId = await createAlert(
        "device",
        "warning",
        "Porte restée ouverte",
        `${dev.name} indique une ouverture depuis plus de ${Number(d.minutes ?? 10)} minutes.`,
        `door_open:${dev.device_id}`,
      );
      break;
    case "tamper":
      alertId = await createAlert(
        "intrusion",
        "critical",
        "Tentative de sabotage",
        `${dev.name} signale une manipulation.`,
      );
      break;
    case "firmware":
      alertId = await createAlert(
        "system",
        "info",
        "Mise à jour installée",
        `Le micrologiciel de ${dev.name} a été mis à jour (${
          String(d.version ?? "").slice(0, 20)
        }). Aucune action requise.`,
      );
      break;
    case "recording": {
      const rec = RecordingData.parse(d);
      const recordingId = crypto.randomUUID();
      const path = `${dev.home_id}/${recordingId}.mp4`;
      const thumb = rec.with_thumbnail === false ? null : `${dev.home_id}/${recordingId}.jpg`;
      const startedAt = rec.started_at ?? new Date().toISOString();
      const { error } = await db.from("recordings").insert({
        id: recordingId,
        home_id: dev.home_id,
        device_id: dev.device_id,
        title: rec.title ?? (rec.motion ? "Mouvement détecté" : "Enregistrement"),
        storage_path: path,
        thumbnail_path: thumb,
        duration_seconds: rec.duration_seconds,
        motion_detected: rec.motion ?? false,
        started_at: startedAt,
        expires_at: new Date(Date.parse(startedAt) + 30 * 86400_000).toISOString(),
      });
      if (error) throw new HttpError(500, "database_error", "Erreur de base de données");
      const video = await db.storage.from("recordings").createSignedUploadUrl(path);
      const image = thumb ? await db.storage.from("recordings").createSignedUploadUrl(thumb) : null;
      response = {
        ok: true,
        recording_id: recordingId,
        upload: {
          video: { path, signed_url: video.data?.signedUrl, token: video.data?.token },
          thumbnail: thumb ? { path: thumb, signed_url: image?.data?.signedUrl, token: image?.data?.token } : null,
        },
      };
      break;
    }
    case "recording_uploaded": {
      const id = uuid.parse(d.recording_id);
      await db.from("recordings").update({ uploaded: true }).eq("id", id).eq("device_id", dev.device_id);
      // Rattache l'enregistrement à la dernière alerte d'intrusion de cet appareil sans vidéo.
      const { data: last } = await db.from("security_alerts").select("id")
        .eq("device_id", dev.device_id).eq("category", "intrusion").is("recording_id", null)
        .gte("created_at", new Date(Date.now() - 10 * 60_000).toISOString())
        .order("created_at", { ascending: false }).limit(1).maybeSingle();
      if (last) await db.from("security_alerts").update({ recording_id: id }).eq("id", last.id);
      break;
    }
  }

  if (alertId) {
    // Notification immédiate ; le balayage pg_cron rattrape tout échec.
    runInBackground(notifyAlert(alertId));
    response.alert_id = alertId;
  }
  return json(req, response);
}));
