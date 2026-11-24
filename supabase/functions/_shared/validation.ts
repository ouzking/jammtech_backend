// Validation stricte des entrées (schémas zod partagés).
import { z } from "npm:zod@3.23.8";
import { HttpError } from "./http.ts";

const E164 = /^\+[1-9][0-9]{7,14}$/;
const SN = /^\+221[37][0-9]{8}$/;

/** E.164 ; pour +221, 9 chiffres commençant par 7 (mobile) ou 3 (fixe). */
export function isValidPhone(p: string): boolean {
  return E164.test(p) && (!p.startsWith("+221") || SN.test(p));
}

export const phone = z.string().trim().max(16).refine(isValidPhone, "Numéro de téléphone invalide (format E.164)");
export const uuid = z.string().uuid();
export const lat = z.number().finite().min(-90).max(90);
export const lng = z.number().finite().min(-180).max(180);
export const accuracy = z.number().finite().min(0).max(100000);
export const code = z.string().regex(/^[0-9]{4,8}$/, "Code invalide");

export function parse<T extends z.ZodTypeAny>(schema: T, input: unknown): z.infer<T> {
  const r = schema.safeParse(input);
  if (!r.success) {
    throw new HttpError(
      400,
      "invalid_input",
      "Données invalides",
      r.error.issues.map((i) => ({ path: i.path.join("."), message: i.message })),
    );
  }
  return r.data;
}

export { z };
