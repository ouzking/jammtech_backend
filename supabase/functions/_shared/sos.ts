// Logique d'envoi des notifications SOS (partagée par sos-trigger, disarm et
// sos-resolve). Tout part en parallèle : push et SMS de secours systématique.
import { optionalEnv } from "./env.ts";
import { push as pushText, sms as smsText } from "./messages.ts";
import { type PushTarget, sendPush } from "./push.ts";
import { sendSms } from "./sms.ts";
import { rpc } from "./supabase.ts";
import { createTrackToken } from "./track-token.ts";

export interface Recipient {
  contact_id: string;
  name: string;
  phone: string;
  contact_user_id: string | null;
  push_tokens: PushTarget[];
  notifications: { id: string; channel: "push" | "sms"; status: string; error?: string | null }[] | null;
}

export interface SosStartResult {
  created: boolean;
  location_shared: boolean;
  event: { id: string; status: string; trigger: string; silent: boolean; started_at: string; client_key: string };
  owner: { id: string; full_name: string; phone: string | null } | null;
  recipients: Recipient[];
  owner_push_tokens: PushTarget[];
}

export interface NotificationUpdate {
  id: string;
  status: "sent" | "failed";
  provider?: string;
  provider_message_id?: string;
  error?: string;
}

export interface DispatchDeps {
  sendPush: typeof sendPush;
  sendSms: typeof sendSms;
  trackSecret?: string;
  trackBaseUrl?: string;
}

function defaultDeps(): DispatchDeps {
  return {
    sendPush,
    sendSms,
    trackSecret: optionalEnv("TRACK_TOKEN_SECRET"),
    trackBaseUrl: optionalEnv("TRACK_PAGE_URL"),
  };
}

function ownerName(owner: SosStartResult["owner"]): string {
  return owner?.full_name?.trim() || owner?.phone || "Un proche";
}

async function trackUrl(deps: DispatchDeps, eventId: string, contactId: string): Promise<string | null> {
  if (!deps.trackSecret || !deps.trackBaseUrl) return null;
  const token = await createTrackToken(deps.trackSecret, eventId, contactId);
  return `${deps.trackBaseUrl.replace(/#.*$/, "")}#${token}`;
}

/**
 * Envoie les notifications « alerte » d'un SOS. Renvoie les mises à jour de
 * statut à enregistrer. Le délai de chaque envoi est borné pour tenir
 * l'objectif de moins de 3 s.
 */
export async function dispatchSosAlert(result: SosStartResult, deps: DispatchDeps = defaultDeps()) {
  const name = ownerName(result.owner);
  const silent = result.event.silent;
  const updates: NotificationUpdate[] = [];
  const deadTokens: string[] = [];

  const jobs = result.recipients.flatMap((r) =>
    (r.notifications ?? []).map(async (n) => {
      if (n.channel === "push") {
        const msg = silent ? pushText.sosSilent(name) : pushText.sosAlert(name);
        const res = await Promise.all(r.push_tokens.map((t) =>
          deps.sendPush(t, {
            ...msg,
            urgent: true,
            channelId: "sos",
            data: {
              type: silent ? "sos_silent" : "sos",
              sos_event_id: result.event.id,
              user_id: result.owner?.id ?? "",
            },
          }, { timeoutMs: 2500 })
        ));
        res.filter((x) => x.unregistered).forEach((x) => deadTokens.push(x.token));
        const ok = res.find((x) => x.ok);
        updates.push(
          ok ? { id: n.id, status: "sent", provider: "fcm", provider_message_id: ok.messageId } : {
            id: n.id,
            status: "failed",
            provider: "fcm",
            error: res.map((x) => x.error).join("; ") || "aucun token",
          },
        );
      } else {
        const url = result.location_shared ? await trackUrl(deps, result.event.id, r.contact_id) : null;
        const body = silent ? smsText.sosSilent(name, url) : smsText.sosAlert(name, result.owner?.phone ?? null, url);
        const s = await deps.sendSms(r.phone, body, { timeoutMs: 2500 });
        updates.push(
          s.ok
            ? { id: n.id, status: "sent", provider: s.provider, provider_message_id: s.messageId }
            : { id: n.id, status: "failed", provider: s.provider, error: s.error },
        );
      }
    })
  );

  // SOS silencieux : message de données invisible vers le téléphone de la
  // victime pour démarrer le suivi de position en arrière-plan.
  if (silent && result.created) {
    jobs.push(
      Promise.all(
        result.owner_push_tokens.map((t) =>
          deps.sendPush(t, { silent: true, data: { type: "silent_tracking", sos_event_id: result.event.id } })
        ),
      ).then(() => undefined),
    );
  }

  await Promise.allSettled(jobs);
  return { updates, deadTokens };
}

export interface SosResolveResult {
  events: string[];
  outcome: "resolved" | "cancelled";
  owner: { id: string; full_name: string; phone: string | null } | null;
  recipients: Recipient[];
}

export async function dispatchSosResolved(result: SosResolveResult, deps: DispatchDeps = defaultDeps()) {
  const name = ownerName(result.owner);
  const cancelled = result.outcome === "cancelled";
  const updates: NotificationUpdate[] = [];
  const jobs = result.recipients.flatMap((r) =>
    (r.notifications ?? []).map(async (n) => {
      if (n.channel === "push") {
        const msg = cancelled ? pushText.sosCancelled(name) : pushText.sosResolved(name);
        const res = await Promise.all(
          r.push_tokens.map((t) => deps.sendPush(t, { ...msg, data: { type: "sos_closed", outcome: result.outcome } })),
        );
        const ok = res.find((x) => x.ok);
        updates.push(
          ok ? { id: n.id, status: "sent", provider: "fcm", provider_message_id: ok.messageId } : {
            id: n.id,
            status: "failed",
            provider: "fcm",
            error: res.map((x) => x.error).join("; ") || "aucun token",
          },
        );
      } else {
        const s = await deps.sendSms(r.phone, cancelled ? smsText.sosCancelled(name) : smsText.sosResolved(name));
        updates.push(
          s.ok ? { id: n.id, status: "sent", provider: s.provider, provider_message_id: s.messageId } : {
            id: n.id,
            status: "failed",
            provider: s.provider,
            error: s.error,
          },
        );
      }
    })
  );
  await Promise.allSettled(jobs);
  return { updates };
}

export async function saveNotificationUpdates(updates: NotificationUpdate[]): Promise<void> {
  if (updates.length === 0) return;
  await rpc("svc_update_sos_notifications", { p_updates: updates });
}

export async function deleteDeadTokens(tokens: string[]): Promise<void> {
  if (tokens.length === 0) return;
  const { adminClient } = await import("./supabase.ts");
  await adminClient().from("push_tokens").delete().in("token", tokens);
}

/** Démarre un SOS puis notifie. Utilisé par sos-trigger et disarm (contrainte). */
export async function startAndDispatchSos(args: {
  userId: string;
  clientKey: string;
  trigger: "button" | "duress_code" | "trip_watchdog";
  silent: boolean;
  lat?: number;
  lng?: number;
  accuracy?: number;
}) {
  const result = await rpc<SosStartResult>("svc_sos_start", {
    p_user_id: args.userId,
    p_client_key: args.clientKey,
    p_trigger: args.trigger,
    p_silent: args.silent,
    p_lat: args.lat ?? null,
    p_lng: args.lng ?? null,
    p_accuracy_m: args.accuracy ?? null,
  });
  const { updates, deadTokens } = await dispatchSosAlert(result);
  await saveNotificationUpdates(updates);
  await deleteDeadTokens(deadTokens).catch(() => {});
  return { result, updates };
}
