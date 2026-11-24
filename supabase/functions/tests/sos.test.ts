import { assert, assertEquals, assertMatch, assertStringIncludes } from "@std/assert";
import { decideChannels, inQuietHours, type Preferences } from "../_shared/notify.ts";
import type { PushMessage, PushResult, PushTarget } from "../_shared/push.ts";
import type { SmsResult } from "../_shared/sms.ts";
import { type DispatchDeps, dispatchSosAlert, dispatchSosResolved, type SosStartResult } from "../_shared/sos.ts";
import { verifyTrackToken } from "../_shared/track-token.ts";

function fakeDeps(opts: { pushDelay?: number; smsDelay?: number; smsFail?: boolean } = {}) {
  const pushes: { target: PushTarget; msg: PushMessage }[] = [];
  const smses: { to: string; body: string }[] = [];
  const deps: DispatchDeps = {
    trackSecret: "s3cret",
    trackBaseUrl: "https://suivi.jammtech.sn/",
    sendPush: async (target: PushTarget, msg: PushMessage): Promise<PushResult> => {
      await new Promise((r) => setTimeout(r, opts.pushDelay ?? 5));
      pushes.push({ target, msg });
      return { ok: true, token: target.token, messageId: "p-" + target.token };
    },
    sendSms: async (to: string, body: string): Promise<SmsResult> => {
      await new Promise((r) => setTimeout(r, opts.smsDelay ?? 5));
      smses.push({ to, body });
      return opts.smsFail
        ? { ok: false, provider: "x", error: "boom" }
        : { ok: true, provider: "twilio", messageId: "s-" + to };
    },
  };
  return { deps, pushes, smses };
}

function sosResult(silent = false): SosStartResult {
  const ev = crypto.randomUUID();
  const contacts = [
    { phone: "+221770000001", app: true },
    { phone: "+221760000002", app: false },
    { phone: "+221780000003", app: false },
  ];
  return {
    created: true,
    location_shared: true,
    event: {
      id: ev,
      status: "active",
      trigger: silent ? "duress_code" : "button",
      silent,
      started_at: "",
      client_key: "",
    },
    owner: { id: crypto.randomUUID(), full_name: "Moussa Ndiaye", phone: "+221771234567" },
    owner_push_tokens: [{ token: "owner-token", platform: "android" }],
    recipients: contacts.map((c, i) => ({
      contact_id: crypto.randomUUID(),
      name: `Proche ${i}`,
      phone: c.phone,
      contact_user_id: c.app ? crypto.randomUUID() : null,
      push_tokens: c.app ? [{ token: `tok-${i}`, platform: "android" as const }] : [],
      notifications: [
        ...(c.app ? [{ id: crypto.randomUUID(), channel: "push" as const, status: "queued" }] : []),
        { id: crypto.randomUUID(), channel: "sms" as const, status: "queued" },
      ],
    })),
  };
}

Deno.test("SOS : 3 proches notifiés en push ET SMS, en parallèle, < 3 s", async () => {
  // Fournisseurs lents (800 ms chacun) : l'envoi parallèle doit tenir < 3 s.
  const { deps, pushes, smses } = fakeDeps({ pushDelay: 800, smsDelay: 800 });
  const t0 = performance.now();
  const { updates } = await dispatchSosAlert(sosResult(), deps);
  const elapsed = performance.now() - t0;
  assert(elapsed < 1500, `envoi en ${elapsed} ms`);
  assertEquals(smses.length, 3, "SMS de secours pour chaque proche");
  assertEquals(pushes.length, 1, "push pour le proche ayant l'app");
  assertEquals(updates.length, 4, "chaque envoi est tracé");
  assert(updates.every((u) => u.status === "sent"));
  assertStringIncludes(smses[0].body, "Moussa Ndiaye a besoin d'aide");
  assertStringIncludes(smses[0].body, "+221771234567");
});

Deno.test("SOS : le lien SMS contient un jeton de suivi valide propre au proche", async () => {
  const { deps, smses } = fakeDeps();
  const r = sosResult();
  await dispatchSosAlert(r, deps);
  const sms = smses.find((s) => s.to === r.recipients[1].phone)!;
  const token = sms.body.match(/#([A-Za-z0-9_-]+)/)![1];
  const claims = await verifyTrackToken("s3cret", token);
  assertEquals(claims?.eventId, r.event.id);
  assertEquals(claims?.contactId, r.recipients[1].contact_id);
});

Deno.test("SOS silencieux : message discret aux proches + suivi invisible chez la victime", async () => {
  const { deps, pushes, smses } = fakeDeps();
  await dispatchSosAlert(sosResult(true), deps);
  assert(smses.every((s) => /NE l'appelez PAS/.test(s.body)));
  const ownerPush = pushes.find((p) => p.target.token === "owner-token");
  assert(ownerPush, "message de données envoyé à la victime");
  assertEquals(ownerPush!.msg.silent, true);
  assertEquals(ownerPush!.msg.title, undefined, "aucun texte visible");
});

Deno.test("SOS : un échec d'envoi est journalisé avec l'erreur", async () => {
  const { deps } = fakeDeps({ smsFail: true });
  const { updates } = await dispatchSosAlert(sosResult(), deps);
  const failed = updates.filter((u) => u.status === "failed");
  assertEquals(failed.length, 3);
  assertMatch(failed[0].error!, /boom/);
});

Deno.test("« Je suis en sécurité » : les proches sont prévenus", async () => {
  const { deps, smses, pushes } = fakeDeps();
  const r = sosResult();
  const { updates } = await dispatchSosResolved({
    events: [r.event.id],
    outcome: "resolved",
    owner: r.owner,
    recipients: r.recipients,
  }, deps);
  assertEquals(updates.length, 4);
  assert(smses.every((s) => s.body.includes("est en sécurité")));
  assertEquals(pushes[0].msg.title, "Moussa Ndiaye est en sécurité");
});

const prefs: Preferences = {
  intrusions_push: true,
  intrusions_sms: true,
  zones_push: true,
  zones_sms: false,
  devices_push: false,
  devices_sms: false,
  contacts_push: true,
  contacts_sms: false,
  sound: true,
  vibration: true,
  quiet_hours_enabled: true,
  quiet_hours_start: "22:00:00",
  quiet_hours_end: "07:00:00",
};

Deno.test("heures calmes (Africa/Dakar, UTC+0) : chevauchement de minuit", () => {
  assert(inQuietHours(prefs, new Date("2026-11-24T23:30:00Z")));
  assert(inQuietHours(prefs, new Date("2026-11-24T06:59:00Z")));
  assert(!inQuietHours(prefs, new Date("2026-11-24T07:00:00Z")));
  assert(!inQuietHours(prefs, new Date("2026-11-24T12:00:00Z")));
  assert(!inQuietHours({ ...prefs, quiet_hours_enabled: false }, new Date("2026-11-24T23:30:00Z")));
});

Deno.test("alertes : préférences et heures calmes, sauf critiques", () => {
  const night = new Date("2026-11-24T23:30:00Z");
  const day = new Date("2026-11-24T12:00:00Z");
  assertEquals(decideChannels({ severity: "critical", category: "intrusion" }, prefs, night), {
    push: true,
    sms: true,
    sound: true,
  });
  assertEquals(decideChannels({ severity: "warning", category: "intrusion" }, prefs, night), {
    push: true,
    sms: false,
    sound: false,
  });
  assertEquals(decideChannels({ severity: "warning", category: "intrusion" }, prefs, day), {
    push: true,
    sms: true,
    sound: true,
  });
  assertEquals(decideChannels({ severity: "info", category: "device" }, prefs, day).push, false);
  assertEquals(decideChannels({ severity: "critical", category: "device" }, prefs, night).push, true);
});
