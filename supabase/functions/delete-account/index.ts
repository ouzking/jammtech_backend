// POST /functions/v1/delete-account
// Suppression complète du compte (exigence App Store / Play Store).
//
// Corps : { confirm: "SUPPRIMER" }
// Effets :
//   * maisons dont l'utilisateur est le seul membre : supprimées avec appareils,
//     alertes et vidéos (fichiers compris) ;
//   * maisons partagées : propriété transférée au membre le plus ancien ;
//   * SOS actifs clos, partages de position arrêtés ;
//   * avatar supprimé ; toutes les lignes liées supprimées en cascade ;
//   * compte Auth supprimé (sessions révoquées).
// Réponse 200 : { deleted: true }
import { handler, HttpError, json, readJson } from "../_shared/http.ts";
import { purgeStorageQueue } from "../_shared/storage.ts";
import { adminClient, requireUser, rpc } from "../_shared/supabase.ts";
import { parse, z } from "../_shared/validation.ts";

const Body = z.object({ confirm: z.literal("SUPPRIMER") }).strict();

Deno.serve(handler(["POST"], async (req) => {
  const user = await requireUser(req);
  parse(Body, await readJson(req));
  const db = adminClient();

  const prep = await rpc<{ deleted_homes: number; avatar_paths: string[] }>("svc_prepare_account_deletion", {
    p_user_id: user.id,
  });

  if (prep.avatar_paths.length) {
    const { error } = await db.storage.from("avatars").remove(prep.avatar_paths);
    if (error) throw new HttpError(500, "storage_error", "Suppression des fichiers impossible. Réessayez.");
  }

  const { error } = await db.auth.admin.deleteUser(user.id);
  if (error) throw new HttpError(500, "auth_error", "Suppression du compte impossible. Réessayez.");

  // Les vidéos des maisons supprimées sont dans la file : on la vide tout de
  // suite (pg_cron rattrape en cas d'échec).
  await purgeStorageQueue().catch((e) => console.error("purge_after_delete_failed", String(e)));

  console.log("account_deleted", JSON.stringify({ deleted_homes: prep.deleted_homes }));
  return json(req, { deleted: true });
}));
