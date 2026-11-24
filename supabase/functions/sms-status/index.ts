// POST /functions/v1/sms-status?provider=twilio|africastalking[&key=…]
// Accusés de livraison des fournisseurs SMS → sos_notifications.status.
//   * Twilio : signature X-Twilio-Signature vérifiée (HMAC-SHA1).
//   * Africa's Talking : pas de signature → clé partagée `key`
//     (SMS_STATUS_WEBHOOK_KEY) dans l'URL de callback.
import { env, optionalEnv, timingSafeEqual } from "../_shared/env.ts";
import { handler, HttpError, json } from "../_shared/http.ts";
import { rpc } from "../_shared/supabase.ts";

async function twilioSignature(authToken: string, url: string, params: URLSearchParams): Promise<string> {
  const data = url + [...params.keys()].sort().map((k) => k + params.get(k)).join("");
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(authToken),
    { name: "HMAC", hash: "SHA-1" },
    false,
    ["sign"],
  );
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data)));
  return btoa(String.fromCharCode(...sig));
}

Deno.serve(handler(["POST"], async (req) => {
  const url = new URL(req.url);
  const provider = url.searchParams.get("provider");
  const params = new URLSearchParams(await req.text());

  if (provider === "twilio") {
    // URL publique exacte configurée comme StatusCallback.
    const publicUrl = `${env("SMS_STATUS_CALLBACK_URL")}?provider=twilio`;
    const expected = await twilioSignature(env("TWILIO_AUTH_TOKEN"), publicUrl, params);
    if (!timingSafeEqual(req.headers.get("x-twilio-signature") ?? "", expected)) {
      throw new HttpError(401, "unauthorized", "Signature invalide");
    }
    const status = params.get("MessageStatus") ?? "";
    const mapped = status === "delivered" ? "delivered" : ["failed", "undelivered"].includes(status) ? "failed" : null;
    if (mapped) {
      await rpc("svc_mark_sms_status", {
        p_provider: "twilio",
        p_message_id: params.get("MessageSid") ?? "",
        p_status: mapped,
        p_error: params.get("ErrorCode"),
      });
    }
    return json(req, { ok: true });
  }

  if (provider === "africastalking") {
    const key = optionalEnv("SMS_STATUS_WEBHOOK_KEY");
    if (!key || !timingSafeEqual(url.searchParams.get("key") ?? "", key)) {
      throw new HttpError(401, "unauthorized", "Clé invalide");
    }
    const status = params.get("status") ?? "";
    const mapped = status === "Success" ? "delivered" : ["Failed", "Rejected"].includes(status) ? "failed" : null;
    if (mapped) {
      await rpc("svc_mark_sms_status", {
        p_provider: "africastalking",
        p_message_id: params.get("id") ?? "",
        p_status: mapped,
        p_error: params.get("failureReason"),
      });
    }
    return json(req, { ok: true });
  }

  throw new HttpError(400, "unknown_provider", "Fournisseur inconnu");
}));
