// Accès aux variables d'environnement / secrets Supabase.

export function env(name: string, fallback?: string): string {
  const v = Deno.env.get(name);
  if (v === undefined || v === "") {
    if (fallback !== undefined) return fallback;
    throw new Error(`Variable d'environnement manquante : ${name}`);
  }
  return v;
}

export function optionalEnv(name: string): string | undefined {
  const v = Deno.env.get(name);
  return v === undefined || v === "" ? undefined : v;
}

/** Comparaison en temps constant de deux chaînes. */
export function timingSafeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  const len = Math.max(ea.length, eb.length);
  for (let i = 0; i < len; i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}

/** Masque un numéro pour les journaux : +22177*****67. Jamais de numéro complet dans les logs. */
export function maskPhone(phone: string | null | undefined): string {
  if (!phone) return "";
  if (phone.length <= 7) return "***";
  return phone.slice(0, 6) + "*".repeat(phone.length - 8) + phone.slice(-2);
}
