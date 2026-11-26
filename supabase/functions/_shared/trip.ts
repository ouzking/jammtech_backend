// Envoi des notifications de trajet à partir de la file `trip_events`.
// Utilisé par les fonctions trip-* (envoi immédiat de leurs événements) et par
// trip-watchdog (pg_cron / pg_net : surveillance et rattrapage).
//
// Règles :
//   * les heures calmes ne s'appliquent jamais aux trajets ;
//   * proche avec l'app → push ; proche sans l'app → SMS avec lien de suivi ;
//   * escalade → SOS complet (push + SMS à tous les proches), idempotent : la
//     clé du SOS est l'identifiant du trajet.
import { optionalEnv } from "./env.ts";
import { dakarTime, push as pushText, sms as smsText, tripModes } from "./messages.ts";
import { type PushTarget, sendPush } from "./push.ts";
import { sendSms } from "./sms.ts";
import { startAndDispatchSos } from "./sos.ts";
import { rpc } from "./supabase.ts";
import { createTripTrackToken } from "./track-token.ts";

export interface TripWatcher {
  contact_id: string;
  name: string;
  phone: string;
  contact_user_id: string | null;
  push_tokens: PushTarget[];
}

export interface TripEvent {
  event_id: number;
  type: string;
  metadata: Record<string, unknown>;
  created_at: string;
  trip: {
    id: string;
    user_id: string;
    mode: string;
    status: string;
    destination_label: string;
    expected_arrival_at: string;
    ended_at: string | null;
    vehicle_plate: string | null;
    last_lat: number | null;
    last_lng: number | null;
    last_battery: number | null;
    checkin_round: number;
    checkin_minutes: number;
  };
  traveler: { id: string; full_name: string; phone: string | null } | null;
  traveler_push_tokens: PushTarget[];
  watchers: TripWatcher[];
}

export interface TripEventResult {
  event_id: number;
  ok: boolean;
  error?: string;
}

export interface TripDeps {
  sendPush: typeof sendPush;
  sendSms: typeof sendSms;
  escalate: (ev: TripEvent) => Promise<void>;
  trackSecret?: string;
  trackBaseUrl?: string;
}

function defaultDeps(): TripDeps {
  return {
    sendPush,
    sendSms,
    escalate: async (ev) => {
      await startAndDispatchSos({
        userId: ev.trip.user_id,
        clientKey: ev.trip.id, // idempotent : un seul SOS par trajet
        trigger: "trip_watchdog",
        silent: false,
        lat: ev.trip.last_lat ?? undefined,
        lng: ev.trip.last_lng ?? undefined,
      });
    },
    trackSecret: optionalEnv("TRACK_TOKEN_SECRET"),
    trackBaseUrl: optionalEnv("TRACK_PAGE_URL"),
  };
}

function travelerName(ev: TripEvent): string {
  return ev.traveler?.full_name?.trim() || ev.traveler?.phone || "Un proche";
}

async function trackUrl(deps: TripDeps, tripId: string, contactId: string): Promise<string | null> {
  if (!deps.trackSecret || !deps.trackBaseUrl) return null;
  const token = await createTripTrackToken(deps.trackSecret, tripId, contactId);
  return `${deps.trackBaseUrl.replace(/#.*$/, "")}#${token}`;
}

/**
 * Prévient les proches qui suivent le trajet : push s'ils ont l'app, sinon SMS
 * (avec lien de suivi si `withLink`). Succès si au moins un envoi a abouti,
 * ou s'il n'y avait personne à prévenir.
 */
async function notifyWatchers(
  ev: TripEvent,
  deps: TripDeps,
  msg: { title: string; body: string },
  data: Record<string, string>,
  smsBody: ((url: string | null) => string) | null,
  opts: { urgent?: boolean; withLink?: boolean } = {},
): Promise<{ ok: boolean; error?: string }> {
  if (ev.watchers.length === 0) return { ok: true };
  const errors: string[] = [];
  let sent = 0;
  await Promise.allSettled(ev.watchers.map(async (w) => {
    if (w.push_tokens.length > 0) {
      const res = await Promise.all(w.push_tokens.map((t) =>
        deps.sendPush(t, {
          ...msg,
          urgent: opts.urgent,
          channelId: opts.urgent ? "sos" : "alerts",
          data: { ...data, trip_id: ev.trip.id, user_id: ev.trip.user_id },
        })
      ));
      if (res.some((r) => r.ok)) {
        sent++;
        return;
      }
      errors.push(`push ${w.contact_id}`);
    }
    if (smsBody) {
      const url = opts.withLink ? await trackUrl(deps, ev.trip.id, w.contact_id) : null;
      const r = await deps.sendSms(w.phone, smsBody(url));
      if (r.ok) sent++;
      else errors.push(`sms ${w.contact_id}: ${r.error ?? ""}`);
    }
  }));
  const ok = sent > 0 || errors.length === 0;
  return ok ? { ok } : { ok, error: errors.join("; ").slice(0, 500) };
}

export async function processTripEvent(ev: TripEvent, deps: TripDeps = defaultDeps()): Promise<TripEventResult> {
  const name = travelerName(ev);
  const mode = tripModes[ev.trip.mode] ?? ev.trip.mode;
  const eta = dakarTime(ev.trip.expected_arrival_at);
  try {
    switch (ev.type) {
      case "started": {
        const r = await notifyWatchers(
          ev,
          deps,
          pushText.tripStarted(name, mode, eta),
          { type: "trip_started" },
          (url) => smsText.tripStarted(name, mode, ev.trip.vehicle_plate, eta, url),
          { withLink: true },
        );
        return { event_id: ev.event_id, ...r };
      }
      case "checkin_requested": {
        const minutes = ev.trip.checkin_minutes || 3;
        const res = await Promise.all(ev.traveler_push_tokens.map((t) =>
          deps.sendPush(t, {
            ...pushText.tripCheckin(minutes),
            urgent: true,
            channelId: "sos",
            data: { type: "trip_checkin", trip_id: ev.trip.id, round: String(ev.metadata.round ?? 1) },
          })
        ));
        let ok = res.some((r) => r.ok);
        // Second tour, ou aucune app joignable : SMS au voyageur.
        if ((Number(ev.metadata.round) >= 2 || !ok) && ev.traveler?.phone) {
          const s = await deps.sendSms(ev.traveler.phone, smsText.tripCheckin(minutes));
          ok = ok || s.ok;
        }
        // Personne de joignable n'empêche pas l'escalade : elle vient du serveur.
        return { event_id: ev.event_id, ok: true, error: ok ? undefined : "voyageur injoignable" };
      }
      case "late": {
        const minutes = Number(ev.metadata.late_minutes ?? 0);
        const r = await notifyWatchers(ev, deps, pushText.tripLate(name, minutes), {
          type: "trip_late",
          late_minutes: String(minutes),
        }, null);
        return { event_id: ev.event_id, ...r };
      }
      case "battery_low": {
        const level = Number(ev.metadata.level ?? ev.trip.last_battery ?? 0);
        const r = await notifyWatchers(
          ev,
          deps,
          pushText.tripBatteryLow(name, level),
          { type: "trip_battery_low", level: String(level) },
          (url) => smsText.tripBatteryLow(name, level, url),
          { withLink: true },
        );
        return { event_id: ev.event_id, ...r };
      }
      case "arrived": {
        const time = dakarTime(ev.trip.ended_at ?? ev.created_at);
        const r = await notifyWatchers(
          ev,
          deps,
          pushText.tripArrived(name, time),
          { type: "trip_arrived", arrived_at: ev.trip.ended_at ?? ev.created_at },
          () => smsText.tripArrived(name, time),
        );
        return { event_id: ev.event_id, ...r };
      }
      case "cancelled": {
        if (ev.metadata.notify === false) return { event_id: ev.event_id, ok: true };
        const r = await notifyWatchers(
          ev,
          deps,
          pushText.tripCancelled(name),
          { type: "trip_cancelled" },
          () => smsText.tripCancelled(name),
        );
        return { event_id: ev.event_id, ...r };
      }
      case "escalated":
        await deps.escalate(ev);
        return { event_id: ev.event_id, ok: true };
      default:
        return { event_id: ev.event_id, ok: true };
    }
  } catch (e) {
    return { event_id: ev.event_id, ok: false, error: e instanceof Error ? e.message : String(e) };
  }
}

/** Réclame puis traite les événements en attente (d'un trajet, ou de tous). */
export async function dispatchTripEvents(tripId: string | null = null, deps?: TripDeps) {
  let processed = 0;
  for (let i = 0; i < 5; i++) {
    const events = await rpc<TripEvent[]>("svc_trip_claim_events", { p_trip_id: tripId, p_limit: 50 });
    if (!events.length) break;
    const results = await Promise.all(events.map((ev) => processTripEvent(ev, deps)));
    await rpc("svc_trip_events_done", { p_results: results });
    processed += events.length;
    if (events.length < 50) break;
  }
  return processed;
}
