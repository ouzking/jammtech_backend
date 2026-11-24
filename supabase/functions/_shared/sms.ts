// Envoi de SMS multi-fournisseurs avec bascule automatique.
//
// SMS_PROVIDERS : liste ordonnée, ex. "twilio,orange" ou "africastalking,twilio".
// Le premier fournisseur est essayé ; en cas d'échec ou de délai dépassé, on
// passe au suivant. Fournisseur `console` : n'envoie rien (développement).
//
// Secrets par fournisseur :
//   twilio          TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN,
//                   TWILIO_MESSAGING_SERVICE_SID ou TWILIO_FROM
//   orange          ORANGE_CLIENT_ID, ORANGE_CLIENT_SECRET, ORANGE_SENDER_ADDRESS
//                   (ex. tel:+2210000), ORANGE_SENDER_NAME (optionnel)
//   africastalking  AT_USERNAME, AT_API_KEY, AT_SENDER_ID (optionnel)
import { env, maskPhone, optionalEnv } from "./env.ts";

export interface SmsResult {
  ok: boolean;
  provider: string;
  messageId?: string;
  error?: string;
}

export interface SmsProvider {
  name: string;
  send(to: string, body: string, signal: AbortSignal): Promise<SmsResult>;
}

type Fetch = typeof fetch;

export function twilioProvider(f: Fetch = fetch): SmsProvider {
  return {
    name: "twilio",
    async send(to, body, signal) {
      const sid = env("TWILIO_ACCOUNT_SID");
      const form = new URLSearchParams({ To: to, Body: body });
      const mss = optionalEnv("TWILIO_MESSAGING_SERVICE_SID");
      if (mss) form.set("MessagingServiceSid", mss);
      else form.set("From", env("TWILIO_FROM"));
      const cb = optionalEnv("SMS_STATUS_CALLBACK_URL");
      if (cb) form.set("StatusCallback", `${cb}?provider=twilio`);
      const res = await f(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
        method: "POST",
        headers: {
          Authorization: "Basic " + btoa(`${sid}:${env("TWILIO_AUTH_TOKEN")}`),
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: form,
        signal,
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        return {
          ok: false,
          provider: "twilio",
          error: `${res.status} ${data?.code ?? ""} ${data?.message ?? ""}`.trim(),
        };
      }
      return { ok: true, provider: "twilio", messageId: data.sid };
    },
  };
}

let orangeToken: { value: string; exp: number } | null = null;

export function orangeProvider(f: Fetch = fetch): SmsProvider {
  return {
    name: "orange",
    async send(to, body, signal) {
      if (!orangeToken || orangeToken.exp < Date.now() + 60_000) {
        const res = await f("https://api.orange.com/oauth/v3/token", {
          method: "POST",
          headers: {
            Authorization: "Basic " + btoa(`${env("ORANGE_CLIENT_ID")}:${env("ORANGE_CLIENT_SECRET")}`),
            "Content-Type": "application/x-www-form-urlencoded",
            Accept: "application/json",
          },
          body: "grant_type=client_credentials",
          signal,
        });
        const tok = await res.json().catch(() => ({}));
        if (!res.ok || !tok.access_token) return { ok: false, provider: "orange", error: `token ${res.status}` };
        orangeToken = { value: tok.access_token, exp: Date.now() + Number(tok.expires_in ?? 3600) * 1000 };
      }
      const sender = env("ORANGE_SENDER_ADDRESS");
      const payload: Record<string, unknown> = {
        address: `tel:${to}`,
        senderAddress: sender,
        outboundSMSTextMessage: { message: body },
      };
      const name = optionalEnv("ORANGE_SENDER_NAME");
      if (name) payload.senderName = name;
      const res = await f(
        `https://api.orange.com/smsmessaging/v1/outbound/${encodeURIComponent(sender)}/requests`,
        {
          method: "POST",
          headers: { Authorization: `Bearer ${orangeToken.value}`, "Content-Type": "application/json" },
          body: JSON.stringify({ outboundSMSMessageRequest: payload }),
          signal,
        },
      );
      const data = await res.json().catch(() => ({}));
      if (!res.ok) return { ok: false, provider: "orange", error: `${res.status}` };
      const ref: string | undefined = data?.outboundSMSMessageRequest?.resourceURL;
      return { ok: true, provider: "orange", messageId: ref?.split("/").pop() };
    },
  };
}

export function africasTalkingProvider(f: Fetch = fetch): SmsProvider {
  return {
    name: "africastalking",
    async send(to, body, signal) {
      const form = new URLSearchParams({ username: env("AT_USERNAME"), to, message: body });
      const from = optionalEnv("AT_SENDER_ID");
      if (from) form.set("from", from);
      const res = await f("https://api.africastalking.com/version1/messaging", {
        method: "POST",
        headers: {
          apiKey: env("AT_API_KEY"),
          Accept: "application/json",
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: form,
        signal,
      });
      const data = await res.json().catch(() => ({}));
      const rcpt = data?.SMSMessageData?.Recipients?.[0];
      if (!res.ok || !rcpt || !["Success", "Sent", "Queued"].includes(rcpt.status)) {
        return { ok: false, provider: "africastalking", error: `${res.status} ${rcpt?.status ?? ""}`.trim() };
      }
      return { ok: true, provider: "africastalking", messageId: rcpt.messageId };
    },
  };
}

export function consoleProvider(): SmsProvider {
  return {
    name: "console",
    send(to, body) {
      // SMS_CONSOLE_SHOW_BODY=true : développement local uniquement (affiche l'OTP).
      const show = optionalEnv("SMS_CONSOLE_SHOW_BODY") === "true";
      console.log("sms_console", maskPhone(to), show ? body : `${body.length} caractères`);
      return Promise.resolve({ ok: true, provider: "console", messageId: crypto.randomUUID() });
    },
  };
}

export function providersFromEnv(f: Fetch = fetch): SmsProvider[] {
  const names = (optionalEnv("SMS_PROVIDERS") ?? "console").split(",").map((s) => s.trim().toLowerCase());
  const map: Record<string, () => SmsProvider> = {
    twilio: () => twilioProvider(f),
    orange: () => orangeProvider(f),
    africastalking: () => africasTalkingProvider(f),
    console: () => consoleProvider(),
  };
  return names.filter((n) => map[n]).map((n) => map[n]());
}

/**
 * Envoie un SMS en essayant les fournisseurs dans l'ordre.
 * `timeoutMs` s'applique à CHAQUE tentative.
 */
export async function sendSms(
  to: string,
  body: string,
  opts: { providers?: SmsProvider[]; timeoutMs?: number } = {},
): Promise<SmsResult> {
  const providers = opts.providers ?? providersFromEnv();
  const timeoutMs = opts.timeoutMs ?? 4000;
  const errors: string[] = [];
  for (const p of providers) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const r = await p.send(to, body, ctrl.signal);
      if (r.ok) return r;
      errors.push(`${p.name}: ${r.error ?? "échec"}`);
    } catch (e) {
      errors.push(`${p.name}: ${ctrl.signal.aborted ? "timeout" : (e instanceof Error ? e.message : String(e))}`);
    } finally {
      clearTimeout(timer);
    }
  }
  console.error("sms_failed", maskPhone(to), errors.join(" | "));
  return {
    ok: false,
    provider: providers.map((p) => p.name).join(","),
    error: errors.join(" | ").slice(0, 500) || "aucun fournisseur SMS",
  };
}
