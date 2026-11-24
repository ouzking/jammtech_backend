// Hook Supabase Auth « Send SMS » : envoie les codes OTP (inscription,
// connexion, mot de passe oublié) via NOTRE chaîne de fournisseurs SMS.
//
// Protections contre l'abus et l'explosion des coûts (SMS pumping) :
//   * signature Standard Webhooks vérifiée (SEND_SMS_HOOK_SECRETS) ;
//   * indicatifs autorisés uniquement (OTP_ALLOWED_PREFIXES, défaut « +221 ») ;
//   * 5 SMS/heure et 10 SMS/jour par numéro (svc_otp_sms_allowed) ;
//   * limites natives d'Auth (30 s entre deux codes, plafonds par IP).
import { Webhook } from "npm:standardwebhooks@1.0.0";
import { env, maskPhone, optionalEnv } from "../_shared/env.ts";
import { sms } from "../_shared/messages.ts";
import { sendSms } from "../_shared/sms.ts";
import { rpc } from "../_shared/supabase.ts";
import { isValidPhone } from "../_shared/validation.ts";

function hookError(status: number, message: string): Response {
  return new Response(JSON.stringify({ error: { http_code: status, message } }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return hookError(405, "Méthode non autorisée");
  const payload = await req.text();
  const secret = env("SEND_SMS_HOOK_SECRETS").replace(/^v1,whsec_/, "");
  let event: { user?: { phone?: string }; sms?: { otp?: string } };
  try {
    event = new Webhook(secret).verify(payload, Object.fromEntries(req.headers)) as typeof event;
  } catch {
    return hookError(401, "Signature invalide");
  }

  const raw = event.user?.phone ?? "";
  const phone = raw.startsWith("+") ? raw : `+${raw}`;
  const otp = event.sms?.otp ?? "";
  if (!isValidPhone(phone) || !/^[0-9]{6}$/.test(otp)) return hookError(400, "Numéro de téléphone invalide");

  const prefixes = (optionalEnv("OTP_ALLOWED_PREFIXES") ?? "+221").split(",").map((p) => p.trim()).filter(Boolean);
  if (!prefixes.some((p) => phone.startsWith(p))) {
    return hookError(400, "Ce numéro n'est pas pris en charge pour le moment.");
  }

  const allowed = await rpc<{ allowed: boolean }>("svc_otp_sms_allowed", { p_phone: phone });
  if (!allowed.allowed) {
    console.warn("otp_rate_limited", maskPhone(phone));
    return hookError(429, "Trop de codes demandés pour ce numéro. Réessayez plus tard.");
  }

  const res = await sendSms(phone, sms.otp(otp), { timeoutMs: 5000 });
  if (!res.ok) return hookError(502, "L'envoi du SMS a échoué. Réessayez dans un instant.");
  return new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } });
});
