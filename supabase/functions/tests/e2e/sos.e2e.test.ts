// Tests de bout en bout sur une pile Supabase locale (CI : job « e2e »).
// Prérequis : `supabase start`, `supabase functions serve`, seed chargé.
// Variables : SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY.
// Ignorés si SUPABASE_URL n'est pas défini (tests unitaires).
import { assert, assertEquals } from "@std/assert";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const url = Deno.env.get("SUPABASE_URL");
const anon = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const ignore = !url;

const MOUSSA = { phone: "+221771234567", password: "JammTech2026!" };
const AWA = { phone: "+221770000001", password: "JammTech2026!" };

async function signIn(creds: { phone: string; password: string }) {
  const sb = createClient(url!, anon, { auth: { persistSession: false } });
  const { data, error } = await sb.auth.signInWithPassword(creds);
  if (error) throw error;
  return { sb, token: data.session!.access_token, userId: data.user!.id };
}

async function call(fn: string, token: string, body: unknown) {
  const t0 = performance.now();
  const res = await fetch(`${url}/functions/v1/${fn}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, apikey: anon, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json(), ms: performance.now() - t0 };
}

function admin(): SupabaseClient {
  return createClient(url!, service, { auth: { persistSession: false } });
}

Deno.test({
  name: "e2e SOS : 3 proches notifiés (push + SMS) en < 3 s, tracé, idempotent, accès retiré à la clôture",
  ignore,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const moussa = await signIn(MOUSSA);
    const awa = await signIn(AWA);
    const key = crypto.randomUUID();

    const r1 = await call("sos-trigger", moussa.token, { client_key: key, lat: 14.6928, lng: -17.4467, accuracy_m: 8 });
    assertEquals(r1.status, 200, JSON.stringify(r1.body));
    assert(r1.ms < 3000, `SOS traité en ${Math.round(r1.ms)} ms`);
    assertEquals(r1.body.created, true);
    assertEquals(r1.body.notified, { push: 1, sms: 3, failed: 0 });

    const { data: notifs } = await admin().from("sos_notifications").select("channel,status")
      .eq("sos_event_id", r1.body.sos_event_id);
    assertEquals(notifs?.length, 4, "chaque envoi est journalisé");
    assert(notifs!.every((n) => n.status === "sent"));

    const r2 = await call("sos-trigger", moussa.token, { client_key: key });
    assertEquals(r2.body.created, false, "rejeu réseau : aucun doublon");
    assertEquals(r2.body.sos_event_id, r1.body.sos_event_id);

    const live = await awa.sb.rpc("get_live_location", { p_user_id: moussa.userId });
    assert(live.data?.trail?.length >= 1, "Awa suit la position pendant le SOS");

    const res = await call("sos-resolve", moussa.token, { outcome: "resolved" });
    assertEquals(res.body.closed, 1);
    const after = await awa.sb.rpc("get_live_location", { p_user_id: moussa.userId });
    assertEquals(after.data, null, "Awa perd l'accès dès la clôture");
  },
});

Deno.test({
  name: "e2e code de contrainte : réponse identique à un désarmement, SOS silencieux invisible",
  ignore,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const moussa = await signIn(MOUSSA);
    const { data: home } = await moussa.sb.from("home_members").select("home_id").eq("role", "owner").single();

    const normal = await call("disarm", moussa.token, {
      home_id: home!.home_id,
      code: "1234",
      lat: 14.69,
      lng: -17.44,
    });
    const duress = await call("disarm", moussa.token, {
      home_id: home!.home_id,
      code: "9999",
      lat: 14.69,
      lng: -17.44,
    });
    assertEquals(normal.status, 200);
    assertEquals(duress.status, normal.status, "même statut HTTP");
    assertEquals(Object.keys(duress.body).sort(), Object.keys(normal.body).sort(), "même forme de réponse");
    assertEquals(duress.body.arm_mode, "disarmed");
    assertEquals(duress.body.warnings, []);

    // Le SOS part en tâche de fond.
    await new Promise((r) => setTimeout(r, 2000));
    const { data: visible } = await moussa.sb.from("sos_events").select("id").eq("status", "active");
    assertEquals(visible, [], "aucune trace visible pour la victime");
    const { data: dash } = await moussa.sb.rpc("get_dashboard");
    assertEquals(dash.active_sos, null);

    const { data: silent } = await admin().from("sos_events").select("id,silent,trigger")
      .eq("user_id", moussa.userId).eq("status", "active");
    assertEquals(silent?.length, 1);
    assertEquals(silent![0].silent, true);
    assertEquals(silent![0].trigger, "duress_code");

    const awa = await signIn(AWA);
    const { data: seen } = await awa.sb.from("sos_events").select("id,silent").eq("status", "active");
    assertEquals(seen?.[0]?.silent, true, "le proche voit l'alerte discrète");

    // Clôture avec le vrai code.
    const closed = await call("sos-resolve", moussa.token, { code: "1234" });
    assertEquals(closed.body.closed, 1);

    const bad = await call("disarm", moussa.token, { home_id: home!.home_id, code: "0000" });
    assertEquals(bad.status, 401);
  },
});

Deno.test({
  name: "e2e RLS : Moussa ne lit aucune donnée privée d'Awa",
  ignore,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async () => {
    const moussa = await signIn(MOUSSA);
    const awa = await signIn(AWA);
    for (const table of ["profiles", "user_settings", "notification_preferences", "push_tokens", "homes"]) {
      const col = table === "profiles" || table === "homes" ? "id" : "user_id";
      const { data } = await moussa.sb.from(table).select("*").neq(col, moussa.userId);
      if (table === "homes") {
        const { data: awaHomes } = await awa.sb.from("homes").select("id");
        const ids = new Set((data ?? []).map((h: { id: string }) => h.id));
        assert(!(awaHomes ?? []).some((h: { id: string }) => ids.has(h.id)), "maison d'Awa invisible");
      } else {
        assertEquals(data, [], `${table} : aucune ligne d'un autre utilisateur`);
      }
    }
  },
});
