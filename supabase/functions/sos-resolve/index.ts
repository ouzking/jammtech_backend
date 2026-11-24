// POST /functions/v1/sos-resolve
// « Je suis en sécurité » : clôt le SOS actif et prévient les proches.
//
// Corps : { sos_event_id?: uuid, outcome?: "resolved" | "cancelled", code?: string }
//   * sans `code` : clôt les SOS visibles de l'utilisateur ;
//   * avec le code de désarmement : clôt AUSSI un éventuel SOS silencieux ;
//   * avec le code de CONTRAINTE : répond comme un succès mais ne clôt rien
//     (et déclenche un SOS silencieux s'il n'y en a pas) — l'agresseur qui
//     force la victime à annuler ne peut pas le détecter.
// Réponse 200 : { closed: number, outcome }
import { handler, json, readJson, runInBackground } from "../_shared/http.ts";
import { errors } from "../_shared/messages.ts";
import {
  dispatchSosResolved,
  saveNotificationUpdates,
  type SosResolveResult,
  startAndDispatchSos,
} from "../_shared/sos.ts";
import { HttpError } from "../_shared/http.ts";
import { requireUser, rpc } from "../_shared/supabase.ts";
import { code, parse, uuid, z } from "../_shared/validation.ts";

const Body = z.object({
  sos_event_id: uuid.optional(),
  outcome: z.enum(["resolved", "cancelled"]).default("resolved"),
  code: code.optional(),
}).strict();

Deno.serve(handler(["POST"], async (req) => {
  const user = await requireUser(req);
  const body = parse(Body, await readJson(req));

  let includeSilent = false;
  if (body.code) {
    const check = await rpc<string>("svc_verify_disarm_code", { p_user_id: user.id, p_code: body.code });
    if (check === "locked") throw new HttpError(429, "locked", errors.locked);
    if (check === "invalid") throw new HttpError(401, "invalid_code", errors.invalidCode);
    if (check === "duress") {
      runInBackground(startAndDispatchSos({
        userId: user.id,
        clientKey: crypto.randomUUID(),
        trigger: "duress_code",
        silent: true,
      }));
      return json(req, { closed: 1, outcome: body.outcome });
    }
    includeSilent = check === "ok";
  }

  const result = await rpc<SosResolveResult>("svc_sos_resolve", {
    p_user_id: user.id,
    p_event_id: body.sos_event_id ?? null,
    p_outcome: body.outcome,
    p_include_silent: includeSilent,
  });

  if (result.recipients.length) {
    const { updates } = await dispatchSosResolved(result);
    await saveNotificationUpdates(updates);
  }
  return json(req, { closed: result.events.length, outcome: body.outcome });
}));
