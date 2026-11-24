import { assert, assertEquals, assertFalse, assertMatch } from "@std/assert";
import { maskPhone, timingSafeEqual } from "../_shared/env.ts";
import { sms } from "../_shared/messages.ts";
import { buildFcmMessage } from "../_shared/push.ts";
import { sendSms, type SmsProvider } from "../_shared/sms.ts";
import { createTrackToken, verifyTrackToken } from "../_shared/track-token.ts";
import { code, isValidPhone, parse, phone } from "../_shared/validation.ts";
import { HttpError } from "../_shared/http.ts";

Deno.test("téléphones : règles E.164 et Sénégal", () => {
  assert(isValidPhone("+221771234567"));
  assert(isValidPhone("+221338211234"));
  assert(isValidPhone("+33612345678"));
  assertFalse(isValidPhone("+221571234567"));
  assertFalse(isValidPhone("+22177123456"));
  assertFalse(isValidPhone("771234567"));
  assertFalse(isValidPhone("+221 77 123 45 67"));
});

Deno.test("validation : erreurs 400 structurées", () => {
  try {
    parse(phone, "+221000");
    throw new Error("devait échouer");
  } catch (e) {
    assert(e instanceof HttpError);
    assertEquals(e.status, 400);
  }
  assertEquals(parse(code, "1234"), "1234");
});

Deno.test("jeton de suivi : aller-retour, falsification, expiration", async () => {
  const ev = crypto.randomUUID();
  const ct = crypto.randomUUID();
  const t = await createTrackToken("secret", ev, ct, 3600);
  assertMatch(t, /^[A-Za-z0-9_-]{70}$/);
  assertEquals(await verifyTrackToken("secret", t), {
    eventId: ev,
    contactId: ct,
    exp: (await verifyTrackToken("secret", t))!.exp,
  });
  assertEquals(await verifyTrackToken("autre-secret", t), null);
  const tampered = t.slice(0, 10) + (t[10] === "A" ? "B" : "A") + t.slice(11);
  assertEquals(await verifyTrackToken("secret", tampered), null, "jeton modifié refusé");
  assertEquals(await verifyTrackToken("secret", t, Date.now() + 2 * 3600_000), null);
  assertEquals(await verifyTrackToken("secret", "court"), null);
});

Deno.test("SMS : bascule sur le fournisseur suivant en cas d'échec ou de délai", async () => {
  const calls: string[] = [];
  const slow: SmsProvider = {
    name: "lent",
    send: (_to, _b, signal) =>
      new Promise((_, reject) => {
        calls.push("lent");
        signal.addEventListener("abort", () => reject(new Error("aborted")));
      }),
  };
  const down: SmsProvider = {
    name: "panne",
    send: () => {
      calls.push("panne");
      return Promise.resolve({ ok: false, provider: "panne", error: "500" });
    },
  };
  const ok: SmsProvider = {
    name: "ok",
    send: () => {
      calls.push("ok");
      return Promise.resolve({ ok: true, provider: "ok", messageId: "m1" });
    },
  };
  const t0 = Date.now();
  const r = await sendSms("+221771234567", "test", { providers: [slow, down, ok], timeoutMs: 100 });
  assert(r.ok);
  assertEquals(r.provider, "ok");
  assertEquals(calls, ["lent", "panne", "ok"]);
  assert(Date.now() - t0 < 1000);

  const fail = await sendSms("+221771234567", "test", { providers: [down], timeoutMs: 100 });
  assertFalse(fail.ok);
  assertMatch(fail.error!, /panne/);
});

Deno.test("SMS : textes en GSM-7 (pas de passage en UCS-2)", () => {
  const gsm7 = /^[@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&'()*+,\-./0-9:;<=>?¡A-ZÄÖÑÜ§¿a-zäöñüà^{}\\\[~\]|€]*$/;
  const url = "https://suivi.jammtech.sn/#" + "a".repeat(70);
  for (
    const text of [
      sms.otp("123456"),
      sms.sosAlert("Moussa Ndiaye", "+221771234567", url),
      sms.sosSilent("Moussa Ndiaye", url),
      sms.sosResolved("Moussa Ndiaye"),
      sms.sosCancelled("Moussa Ndiaye"),
    ]
  ) {
    assertMatch(text, gsm7, text);
  }
});

Deno.test("push : SOS urgent et message silencieux de suivi", () => {
  const urgent = buildFcmMessage({ token: "t", platform: "android" }, { title: "SOS", body: "b", urgent: true });
  // deno-lint-ignore no-explicit-any
  const a = urgent as any;
  assertEquals(a.android.priority, "HIGH");
  assertEquals(a.android.notification.channel_id, "sos");
  assertEquals(a.apns.payload.aps["interruption-level"], "time-sensitive");

  const silentMsg = buildFcmMessage({ token: "t", platform: "ios" }, {
    silent: true,
    data: { type: "silent_tracking" },
  });
  // deno-lint-ignore no-explicit-any
  const silent = silentMsg as any;
  assertEquals(silent.notification, undefined, "aucune notification visible");
  assertEquals(silent.apns.payload.aps["content-available"], 1);
});

Deno.test("utilitaires : masquage et comparaison en temps constant", () => {
  assertEquals(maskPhone("+221771234567"), "+22177*****67");
  assert(timingSafeEqual("abc", "abc"));
  assertFalse(timingSafeEqual("abc", "abd"));
  assertFalse(timingSafeEqual("abc", "abcd"));
});
