// Vidage de la file de suppression des fichiers Storage.
import { adminClient, rpc } from "./supabase.ts";

export async function purgeStorageQueue(maxBatches = 5): Promise<{ files_deleted: number; files_failed: number }> {
  let deleted = 0;
  let failed = 0;
  for (let i = 0; i < maxBatches; i++) {
    const batch = await rpc<{ id: number; bucket: string; path: string }[]>("svc_storage_deletion_batch", {
      p_limit: 200,
    });
    if (!batch.length) break;
    const byBucket = new Map<string, { id: number; path: string }[]>();
    for (const b of batch) byBucket.set(b.bucket, [...(byBucket.get(b.bucket) ?? []), b]);

    const done: number[] = [];
    const ko: number[] = [];
    let lastError: string | null = null;
    for (const [bucket, items] of byBucket) {
      const { error } = await adminClient().storage.from(bucket).remove(items.map((x) => x.path));
      // Un fichier déjà absent n'est pas une erreur : remove() ne la signale pas.
      if (error) {
        ko.push(...items.map((x) => x.id));
        lastError = error.message;
      } else {
        done.push(...items.map((x) => x.id));
      }
    }
    await rpc("svc_storage_deletion_done", { p_done: done, p_failed: ko, p_error: lastError });
    deleted += done.length;
    failed += ko.length;
    if (ko.length) break;
  }
  return { files_deleted: deleted, files_failed: failed };
}
