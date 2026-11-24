// Notification des alertes de sécurité selon les préférences de chaque
// destinataire. Règles :
//   * le type d'alerte détermine les préférences consultées
//     (intrusion → intrusions_*, zone → zones_*, device/system → devices_*,
//      contact → contacts_*) ;
//   * heures calmes (Africa/Dakar) : pas de SMS, push sans son ;
//   * `critical` : ignore les heures calmes, push toujours envoyé.
import { maskPhone } from "./env.ts";
import { sms as smsText } from "./messages.ts";
import { type PushTarget, sendPush } from "./push.ts";
import { sendSms } from "./sms.ts";
import { adminClient, rpc } from "./supabase.ts";

export interface Preferences {
  intrusions_push: boolean;
  intrusions_sms: boolean;
  zones_push: boolean;
  zones_sms: boolean;
  devices_push: boolean;
  devices_sms: boolean;
  contacts_push: boolean;
  contacts_sms: boolean;
  sound: boolean;
  vibration: boolean;
  quiet_hours_enabled: boolean;
  quiet_hours_start: string; // "22:00:00"
  quiet_hours_end: string;
}

export interface AlertRow {
  id: string;
  title: string;
  description: string;
  severity: "critical" | "warning" | "info";
  category: "intrusion" | "zone" | "device" | "contact" | "system";
  location_label: string | null;
  home_id: string | null;
  recording_id: string | null;
}

export interface AlertRecipient {
  user_id: string;
  phone: string | null;
  preferences: Preferences | null;
  push_tokens: PushTarget[];
}

const DEFAULT_PREFS: Preferences = {
  intrusions_push: true,
  intrusions_sms: true,
  zones_push: true,
  zones_sms: false,
  devices_push: true,
  devices_sms: false,
  contacts_push: true,
  contacts_sms: false,
  sound: true,
  vibration: true,
  quiet_hours_enabled: false,
  quiet_hours_start: "22:00:00",
  quiet_hours_end: "07:00:00",
};

function minutes(t: string): number {
  const [h, m] = t.split(":").map(Number);
  return h * 60 + (m || 0);
}

/** Heure locale à Dakar en minutes depuis minuit. */
export function dakarMinutes(now: Date): number {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Africa/Dakar",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).formatToParts(now);
  const h = Number(parts.find((p) => p.type === "hour")?.value ?? 0) % 24;
  const m = Number(parts.find((p) => p.type === "minute")?.value ?? 0);
  return h * 60 + m;
}

export function inQuietHours(p: Preferences, now: Date): boolean {
  if (!p.quiet_hours_enabled) return false;
  const start = minutes(p.quiet_hours_start);
  const end = minutes(p.quiet_hours_end);
  const cur = dakarMinutes(now);
  if (start === end) return false;
  return start < end ? cur >= start && cur < end : cur >= start || cur < end;
}

export interface Decision {
  push: boolean;
  sms: boolean;
  sound: boolean;
}

export function decideChannels(
  alert: Pick<AlertRow, "severity" | "category">,
  prefs: Preferences | null,
  now: Date,
): Decision {
  const p = prefs ?? DEFAULT_PREFS;
  const key = alert.category === "intrusion"
    ? "intrusions"
    : alert.category === "zone"
    ? "zones"
    : alert.category === "contact"
    ? "contacts"
    : "devices";
  const wantPush = p[`${key}_push` as keyof Preferences] as boolean;
  const wantSms = p[`${key}_sms` as keyof Preferences] as boolean;
  if (alert.severity === "critical") {
    return { push: true, sms: wantSms, sound: true };
  }
  const quiet = inQuietHours(p, now);
  return { push: wantPush, sms: wantSms && !quiet, sound: p.sound && !quiet };
}

/** Notifie tous les destinataires d'une alerte puis la marque comme notifiée. */
export async function notifyAlert(alertId: string, now = new Date()) {
  const data = await rpc<{ alert: AlertRow | null; recipients: AlertRecipient[] }>("svc_alert_recipients", {
    p_alert_id: alertId,
  });
  if (!data?.alert) return { sent: 0 };
  const alert = data.alert;
  let sent = 0;
  const dead: string[] = [];

  await Promise.allSettled(data.recipients.map(async (r) => {
    const d = decideChannels(alert, r.preferences, now);
    const jobs: Promise<unknown>[] = [];
    if (d.push && r.push_tokens.length) {
      jobs.push(Promise.all(r.push_tokens.map((t) =>
        sendPush(t, {
          title: alert.title,
          body: alert.location_label ? `${alert.location_label} — ${alert.description}` : alert.description,
          urgent: alert.severity === "critical",
          sound: d.sound,
          channelId: alert.severity === "critical" ? "critical" : "alerts",
          data: { type: "alert", alert_id: alert.id, severity: alert.severity, recording_id: alert.recording_id ?? "" },
        }).then((res) => {
          if (res.ok) sent++;
          if (res.unregistered) dead.push(res.token);
        })
      )));
    }
    if (d.sms && r.phone) {
      jobs.push(
        sendSms(r.phone, smsText.alert(alert.title, alert.location_label)).then((res) => {
          if (res.ok) sent++;
          else console.error("alert_sms_failed", maskPhone(r.phone));
        }),
      );
    }
    await Promise.allSettled(jobs);
  }));

  if (dead.length) await adminClient().from("push_tokens").delete().in("token", dead);
  await rpc("svc_mark_alert_notified", { p_alert_id: alertId });
  return { sent };
}
