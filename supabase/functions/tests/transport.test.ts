import { assert, assertEquals, assertMatch, assertStringIncludes } from "@std/assert";
import { dakarTime, sms } from "../_shared/messages.ts";
import type { PushMessage, PushResult, PushTarget } from "../_shared/push.ts";
import type { SmsResult } from "../_shared/sms.ts";
import { createTrackToken, verifyAnyTrackToken } from "../_shared/track-token.ts";
import { processTripEvent, type TripDeps, type TripEvent } from "../_shared/trip.ts";
import { evaluateTrackerAlerts } from "../_shared/vehicle.ts";

function fake() {
  const pushes: { target: PushTarget; msg: PushMessage }[] = [];
  const smses: { to: string; body: string }[] = [];
  let escalations = 0;
  const deps: TripDeps = {
    trackSecret: "s3cret",
    trackBaseUrl: "https://suivi.jammtech.sn/",
    sendPush: (target: PushTarget, msg: PushMessage): Promise<PushResult> => {
      pushes.push({ target, msg });
      return Promise.resolve({ ok: true, token: target.token, messageId: "p" });
    },
    sendSms: (to: string, body: string): Promise<SmsResult> => {
      smses.push({ to, body });
      return Promise.resolve({ ok: true, provider: "test", messageId: "s" });
    },
    escalate: () => {
      escalations++;
      return Promise.resolve();
    },
  };
  return { deps, pushes, smses, escalations: () => escalations };
}

function tripEvent(type: string, metadata: Record<string, unknown> = {}): TripEvent {
  return {
    event_id: 1,
    type,
    metadata,
    created_at: "2026-11-26T20:14:00Z",
    trip: {
      id: crypto.randomUUID(),
      user_id: crypto.randomUUID(),
      mode: "taxi",
      status: "active",
      destination_label: "Mermoz",
      expected_arrival_at: "2026-11-26T20:30:00Z",
      ended_at: type === "arrived" ? "2026-11-26T20:14:00Z" : null,
      vehicle_plate: "DK1234AB",
      last_lat: 14.7,
      last_lng: -17.45,
      last_battery: 5,
      checkin_round: Number(metadata.round ?? 0),
      checkin_minutes: 3,
    },
    traveler: { id: crypto.randomUUID(), full_name: "Awa Ndiaye", phone: "+221770000001" },
    traveler_push_tokens: [{ token: "traveler", platform: "android" }],
    watchers: [
      {
        contact_id: crypto.randomUUID(),
        name: "Avec app",
        phone: "+221770000002",
        contact_user_id: crypto.randomUUID(),
        push_tokens: [{ token: "w1", platform: "ios" }],
      },
      {
        contact_id: crypto.randomUUID(),
        name: "Sans app",
        phone: "+221760000003",
        contact_user_id: null,
        push_tokens: [],
      },
    ],
  };
}

Deno.test("trajet démarré : push au proche avec l'app, SMS + lien de suivi au proche sans l'app", async () => {
  const f = fake();
  const ev = tripEvent("started");
  const r = await processTripEvent(ev, f.deps);
  assert(r.ok);
  assertEquals(f.pushes.length, 1);
  assertEquals(f.pushes[0].msg.data?.type, "trip_started");
  assertEquals(f.smses.length, 1);
  assertEquals(f.smses[0].to, "+221760000003");
  assertStringIncludes(f.smses[0].body, "DK1234AB");
  const token = f.smses[0].body.match(/#([A-Za-z0-9_-]+)/)![1];
  const claims = await verifyAnyTrackToken("s3cret", token);
  assertEquals(claims?.kind, "trip");
  assertEquals(claims?.id, ev.trip.id);
  assertEquals(claims?.contactId, ev.watchers[1].contact_id);
});

Deno.test("jetons : un lien de trajet n'ouvre jamais un SOS (et inversement)", async () => {
  const id = crypto.randomUUID();
  const ct = crypto.randomUUID();
  const sosToken = await createTrackToken("k", id, ct);
  assertEquals((await verifyAnyTrackToken("k", sosToken))?.kind, "sos");
  assertEquals(await verifyAnyTrackToken("autre", sosToken), null);
});

Deno.test("« Tout va bien ? » : push urgent au voyageur, SMS en plus au second tour", async () => {
  const f1 = fake();
  await processTripEvent(tripEvent("checkin_requested", { round: 1 }), f1.deps);
  assertEquals(f1.pushes.length, 1);
  assertEquals(f1.pushes[0].target.token, "traveler");
  assertEquals(f1.pushes[0].msg.urgent, true);
  assertEquals(f1.pushes[0].msg.data?.type, "trip_checkin");
  assertEquals(f1.smses.length, 0);

  const f2 = fake();
  await processTripEvent(tripEvent("checkin_requested", { round: 2 }), f2.deps);
  assertEquals(f2.smses.length, 1);
  assertEquals(f2.smses[0].to, "+221770000001");
});

Deno.test("escalade : déclenche le SOS côté serveur", async () => {
  const f = fake();
  const r = await processTripEvent(tripEvent("escalated"), f.deps);
  assert(r.ok);
  assertEquals(f.escalations(), 1);
});

Deno.test("arrivée et annulation", async () => {
  const f = fake();
  await processTripEvent(tripEvent("arrived"), f.deps);
  assertEquals(f.pushes[0].msg.data?.type, "trip_arrived");
  assertStringIncludes(f.smses[0].body, `est bien arrivé(e) à ${dakarTime("2026-11-26T20:14:00Z")}`);
  assertEquals(dakarTime("2026-11-26T20:14:00Z"), "20 h 14");

  const g = fake();
  const r = await processTripEvent(tripEvent("cancelled", { notify: false }), g.deps);
  assert(r.ok);
  assertEquals(g.pushes.length + g.smses.length, 0, "annulation immédiate : personne n'est dérangé");
});

Deno.test("batterie faible et retard", async () => {
  const f = fake();
  await processTripEvent(tripEvent("battery_low", { level: 5 }), f.deps);
  assertEquals(f.pushes[0].msg.data?.type, "trip_battery_low");
  assertMatch(f.smses[0].body, /batterie de Awa Ndiaye à 5 %.*#/);

  const g = fake();
  await processTripEvent(tripEvent("late", { late_minutes: 20 }), g.deps);
  assertEquals(g.pushes[0].msg.title, "Awa Ndiaye n'est pas encore arrivé·e");
  assertEquals(g.smses.length, 0, "retard : push uniquement");
});

Deno.test("SMS de trajet en GSM-7", () => {
  const gsm7 = /^[@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&'()*+,\-./0-9:;<=>?¡A-ZÄÖÑÜ§¿a-zäöñüà^{}\\\[~\]|€]*$/;
  const url = "https://suivi.jammtech.sn/#" + "a".repeat(70);
  for (
    const t of [
      sms.tripStarted("Awa Ndiaye", "transport en commun", "DK1234AB", "20 h 14", url),
      sms.tripArrived("Awa Ndiaye", "20 h 14"),
      sms.tripCancelled("Awa Ndiaye"),
      sms.tripBatteryLow("Awa Ndiaye", 5, url),
      sms.tripCheckin(3),
    ]
  ) assertMatch(t, gsm7, t);
});

const base = {
  trackerId: "t1",
  vehicleLabel: "Toyota DK1234AB",
  previous: { ignition: false, external_power: true, inside_geofence: true },
  rules: { allowed_start: "06:00:00", allowed_end: "22:00:00", night_ignition_alert: true, geofence_alert: true },
  geofences: [{ id: "g", name: "Maison", lat: 14.7167, lng: -17.4677, radius_m: 200 }],
};

Deno.test("traceur : aucune alerte en usage normal de jour", () => {
  const r = evaluateTrackerAlerts({
    ...base,
    update: { type: "position", lat: 14.7168, lng: -17.4676, speed_kmh: 30, ignition: true },
  }, new Date("2026-11-26T10:00:00Z"));
  assertEquals(r.alerts, []);
  assertEquals(r.insideGeofence, true);
});

Deno.test("traceur : débranchement, nuit, hors heures, sortie de zone", () => {
  const night = new Date("2026-11-26T23:30:00Z");
  const r = evaluateTrackerAlerts({
    ...base,
    update: { type: "position", lat: 14.75, lng: -17.5, speed_kmh: 40, ignition: true, external_power: false },
  }, night);
  const titles = r.alerts.map((a) => a.title).sort();
  assertEquals(titles, [
    "Contact moteur la nuit",
    "Mouvement hors des heures autorisées",
    "Sortie de zone",
    "Traceur débranché",
  ]);
  assertEquals(r.insideGeofence, false);
  assert(r.alerts.every((a) => a.dedupe.length > 0));

  const shock = evaluateTrackerAlerts({ ...base, update: { type: "shock" } }, new Date("2026-11-26T10:00:00Z"));
  assertEquals(shock.alerts.map((a) => a.title), ["Choc détecté"]);
});
