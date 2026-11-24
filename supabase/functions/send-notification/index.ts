// POST /functions/v1/send-notification   (interne : en-tête x-cron-secret)
// Envoie les notifications d'une alerte selon les préférences des
// destinataires, ou balaie les alertes non encore notifiées (pg_cron).
//
// Corps : { alert_id: uuid } | { sweep: true }
import { handler, json, readJson } from "../_shared/http.ts";
import { notifyAlert } from "../_shared/notify.ts";
import { requireInternal, rpc } from "../_shared/supabase.ts";
import { parse, uuid, z } from "../_shared/validation.ts";

const Body = z.union([
  z.object({ alert_id: uuid }).strict(),
  z.object({ sweep: z.literal(true) }).strict(),
]);

Deno.serve(handler(["POST"], async (req) => {
  requireInternal(req);
  const body = parse(Body, await readJson(req));

  const ids = "alert_id" in body ? [body.alert_id] : await rpc<string[]>("svc_pending_alerts", { p_limit: 50 });
  let sent = 0;
  for (const id of ids ?? []) {
    try {
      sent += (await notifyAlert(id)).sent;
    } catch (e) {
      console.error("notify_alert_failed", id, e instanceof Error ? e.message : String(e));
    }
  }
  return json(req, { processed: ids?.length ?? 0, sent });
}));
