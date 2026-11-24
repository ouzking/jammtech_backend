// POST /functions/v1/purge-expired   (interne : en-tête x-cron-secret)
// Appelée toutes les 5 min par pg_cron :
//   1. supprime les enregistrements expirés (> 30 jours) — le trigger SQL met
//      leurs fichiers (vidéo + miniature) en file de suppression ;
//   2. vide la file de suppression via l'API Storage.
import { handler, json } from "../_shared/http.ts";
import { purgeStorageQueue } from "../_shared/storage.ts";
import { adminClient, requireInternal, rpc } from "../_shared/supabase.ts";

Deno.serve(handler(["POST"], async (req) => {
  requireInternal(req);
  const expired = await rpc<{ id: string }[]>("svc_expired_recordings", { p_limit: 500 });
  if (expired.length) {
    const { error } = await adminClient().from("recordings").delete().in("id", expired.map((r) => r.id));
    if (error) console.error("purge_recordings_failed", error.message);
  }
  const files = await purgeStorageQueue();
  return json(req, { recordings_deleted: expired.length, ...files });
}));
