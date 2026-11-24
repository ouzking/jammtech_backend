// Clients Supabase et authentification des appelants.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { env, optionalEnv, timingSafeEqual } from "./env.ts";
import { HttpError } from "./http.ts";

let admin: SupabaseClient | null = null;

/** Client `service_role` : contourne la RLS. Ne jamais exposer côté client. */
export function adminClient(): SupabaseClient {
  if (!admin) {
    admin = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
  }
  return admin;
}

export interface AuthUser {
  id: string;
  phone?: string;
  jwt: string;
}

/** Vérifie le JWT utilisateur (en-tête Authorization) auprès de Supabase Auth. */
export async function requireUser(req: Request): Promise<AuthUser> {
  const header = req.headers.get("authorization") ?? "";
  const jwt = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!jwt) throw new HttpError(401, "unauthorized", "Authentification requise");
  const { data, error } = await adminClient().auth.getUser(jwt);
  if (error || !data?.user) throw new HttpError(401, "unauthorized", "Session invalide ou expirée");
  return { id: data.user.id, phone: data.user.phone, jwt };
}

/** Appels internes (pg_cron, autres fonctions) : en-tête x-cron-secret. */
export function requireInternal(req: Request): void {
  const expected = optionalEnv("CRON_SECRET");
  const got = req.headers.get("x-cron-secret") ?? "";
  if (!expected || !got || !timingSafeEqual(got, expected)) {
    throw new HttpError(401, "unauthorized", "Appel interne non autorisé");
  }
}

/** Appelle une RPC et lève une HttpError en cas d'échec. */
export async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await adminClient().rpc(fn, args);
  if (error) {
    console.error("rpc_failed", fn, error.code, error.message);
    throw new HttpError(500, "database_error", "Erreur de base de données");
  }
  return data as T;
}
