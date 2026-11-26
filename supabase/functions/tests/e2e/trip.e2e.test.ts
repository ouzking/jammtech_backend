// Tests de bout en bout « Trajet sécurisé » sur une pile Supabase locale (CI).
// Ignorés si SUPABASE_URL n'est pas défini.
import { assert, assertEquals } from "@std/assert";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL");
const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const cronSecret = Deno.env.get("CRON_SECRET") ?? "change-me-local-cron-secret";
const ignore = !url;

const MOUSSA = { phone: "+221771234567", password: "JammTech2026!" };
const AWA = { phone: "+221770000001", password: "JammTech2026!" };

async function signIn(creds: { phone: string; password: string }) {
  const sb = createClient(url!, anon, { auth: { persistSession: false } });
  const { data, error } = await sb.auth.signInWithPassword(creds);
  if (error) throw error;
  return { sb, token: data.session!.access_token, userId: data.user!.id };
}

async function call(fn: string, token: string, body: unknown, extra: Record<string, string> = {}) {
  const t0 = performance.now();
  const res = await fetch(`${url}/functions/v1/${fn}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, apikey: anon, "Content-Type": "application/json", ...extra },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json(), ms: performance.now() - t0 };
}

const admin = (): SupabaseClient => createClient(url!, service, { auth: { persistSession: false } });
const watchdog = (token: string) => call("trip-watchdog", token, { tick: true }, { "x-cron-secret": cronSecret });

async function contactIds(sb: SupabaseClient) {
  const { data } = await sb.from("trusted_contacts").select("id, phone");
  return Object.fromEntries((data ?? []).map((c: { id: string; phone: string }) => [c.phone, c.id]));
}

function tripBody(watchers: string[]) {
  return {
    client_key: crypto.randomUUID(),
    mode: "taxi",
    destination: { lat: 14.7167, lng: -17.4677, label: "Maison, Mermoz" },
    expected_arrival_at: new Date(Date.now() + 30 * 60_000).toISOString(),
    watcher_contact_ids: watchers,
    vehicle_plate: "DK-1234-AB",
    position: { lat: 14.6928, lng: -17.4467, accuracy_m: 10 },
  };
}

const opts = { ignore, sanitizeResources: false, sanitizeOps: false };

Deno.test({
  ...opts,
  name: "e2e trajet : 2 proches prévenus, idempotent, téléphone muet → SOS déclenché par le serveur",
  fn: async () => {
    const moussa = await signIn(MOUSSA);
    const awa = await signIn(AWA);
    const c = await contactIds(moussa.sb);
    const body = tripBody([c["+221770000001"], c["+221760000002"]]);

    const r1 = await call("trip-start", moussa.token, body);
    assertEquals(r1.status, 200, JSON.stringify(r1.body));
    assertEquals(r1.body.created, true);
    assertEquals(r1.body.watchers, 2);
    const tripId = r1.body.trip.id as string;

    const r2 = await call("trip-start", moussa.token, body);
    assertEquals(r2.body.created, false, "rejeu réseau : aucun doublon");

    const { data: started } = await admin().from("trip_events").select("dispatched_at,dispatch_error")
      .eq("trip_id", tripId).eq("type", "started").single();
    assert(started?.dispatched_at, `départ notifié (push Awa + SMS Ibrahima) ${started?.dispatch_error ?? ""}`);

    const live = await awa.sb.rpc("get_trip_live", { p_trip_id: tripId });
    assertEquals(live.data?.vehicle_plate, "DK1234AB", "Awa suit le trajet et voit la plaque");

    // Le téléphone se tait : plus aucune position, heure d'arrivée dépassée.
    await admin().from("trips").update({
      started_at: new Date(Date.now() - 2 * 3600_000).toISOString(),
      expected_arrival_at: new Date(Date.now() - 20 * 60_000).toISOString(),
      last_location_at: new Date(Date.now() - 3600_000).toISOString(),
    }).eq("id", tripId);

    await watchdog(moussa.token);
    let { data: t } = await admin().from("trips").select("checkin_round,status").eq("id", tripId).single();
    assertEquals(t?.checkin_round, 1, "« Tout va bien ? » (tour 1)");

    await admin().from("trips").update({ checkin_requested_at: new Date(Date.now() - 4 * 60_000).toISOString() })
      .eq("id", tripId);
    await watchdog(moussa.token);
    ({ data: t } = await admin().from("trips").select("checkin_round,status").eq("id", tripId).single());
    assertEquals(t?.checkin_round, 2, "relance (tour 2)");

    await admin().from("trips").update({ checkin_requested_at: new Date(Date.now() - 3 * 60_000).toISOString() })
      .eq("id", tripId);
    await watchdog(moussa.token);

    const { data: esc } = await admin().from("trips").select("status,sos_event_id").eq("id", tripId).single();
    assertEquals(esc?.status, "escalated", "escalade sans aucune action du téléphone");
    assert(esc?.sos_event_id, "SOS créé et rattaché au trajet");
    const { data: notifs } = await admin().from("sos_notifications").select("channel,status")
      .eq("sos_event_id", esc!.sos_event_id);
    assert((notifs?.length ?? 0) >= 4, "tous les proches alertés (push + SMS)");

    const closed = await call("sos-resolve", moussa.token, { outcome: "resolved" });
    assertEquals(closed.body.closed, 1);
    const after = await awa.sb.rpc("get_trip_live", { p_trip_id: tripId });
    assertEquals(after.data, null, "Awa perd l'accès une fois le trajet terminé");
  },
});

Deno.test({
  ...opts,
  name: "e2e trajet : « Tout va bien ? » avec le code de contrainte = réponse identique + SOS silencieux",
  fn: async () => {
    const moussa = await signIn(MOUSSA);
    const awa = await signIn(AWA);
    const c = await contactIds(moussa.sb);
    const start = await call("trip-start", moussa.token, tripBody([c["+221770000001"]]));
    assertEquals(start.status, 200, JSON.stringify(start.body));
    const tripId = start.body.trip.id as string;

    const ok = await call("trip-checkin", moussa.token, { trip_id: tripId, code: "1234" });
    const duress = await call("trip-checkin", moussa.token, { trip_id: tripId, code: "9999" });
    assertEquals(ok.status, 200);
    assertEquals(duress.status, ok.status, "même statut");
    assertEquals(Object.keys(duress.body).sort(), Object.keys(ok.body).sort(), "même forme");
    assertEquals(duress.body.ok, true);

    await new Promise((r) => setTimeout(r, 2000));
    const { data: visible } = await moussa.sb.from("sos_events").select("id").eq("status", "active");
    assertEquals(visible, [], "rien de visible pour Moussa");
    const { data: events } = await moussa.sb.from("trip_events").select("type").eq("trip_id", tripId);
    assert(!(events ?? []).some((e: { type: string }) => e.type === "checkin_duress"), "aucune trace dans le journal");
    const { data: seen } = await awa.sb.from("sos_events").select("silent").eq("status", "active");
    assertEquals(seen?.[0]?.silent, true, "Awa reçoit l'alerte discrète");

    const bad = await call("trip-checkin", moussa.token, { trip_id: tripId, code: "0000" });
    assertEquals(bad.status, 401);

    await call("sos-resolve", moussa.token, { code: "1234" });
    const arrived = await call("trip-arrive", moussa.token, { trip_id: tripId });
    assertEquals(arrived.body.status, "arrived");
  },
});

Deno.test({
  ...opts,
  name: "e2e trajet : un proche non choisi ne voit rien",
  fn: async () => {
    const moussa = await signIn(MOUSSA);
    const awa = await signIn(AWA);
    const c = await contactIds(moussa.sb);
    const start = await call("trip-start", moussa.token, tripBody([c["+221760000002"]]));
    const tripId = start.body.trip.id as string;

    const { data: trips } = await awa.sb.from("trips").select("id").eq("id", tripId);
    assertEquals(trips, [], "Awa n'est pas watcher : trajet invisible");
    const live = await awa.sb.rpc("get_trip_live", { p_trip_id: tripId });
    assertEquals(live.data, null);

    const cancel = await call("trip-cancel", moussa.token, { trip_id: tripId });
    assertEquals(cancel.body.watchers_notified, false, "annulation immédiate : personne n'est dérangé");
  },
});
