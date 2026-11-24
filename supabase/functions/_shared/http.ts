// Réponses HTTP, CORS et erreurs typées communes à toutes les fonctions.

export class HttpError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public details?: unknown,
  ) {
    super(message);
  }
}

const allowedOrigins = (Deno.env.get("ALLOWED_ORIGINS") ?? "*")
  .split(",")
  .map((o) => o.trim())
  .filter(Boolean);

export function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("origin") ?? "";
  const allow = allowedOrigins.includes("*") ? "*" : allowedOrigins.includes(origin) ? origin : allowedOrigins[0] ?? "";
  return {
    "Access-Control-Allow-Origin": allow,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
    "Vary": "Origin",
  };
}

export function json(req: Request, body: unknown, status = 200, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...corsHeaders(req),
      ...extra,
    },
  });
}

export function errorResponse(req: Request, err: unknown): Response {
  if (err instanceof HttpError) {
    return json(req, { error: { code: err.code, message: err.message, details: err.details } }, err.status);
  }
  console.error("unhandled_error", err instanceof Error ? err.message : String(err));
  return json(req, { error: { code: "internal_error", message: "Erreur interne. Réessayez." } }, 500);
}

/** Enveloppe un handler : CORS, méthodes autorisées, gestion des erreurs. */
export function handler(
  methods: string[],
  fn: (req: Request) => Promise<Response>,
): (req: Request) => Promise<Response> {
  return async (req: Request) => {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(req) });
    }
    if (!methods.includes(req.method)) {
      return json(req, { error: { code: "method_not_allowed", message: "Méthode non autorisée" } }, 405);
    }
    try {
      return await fn(req);
    } catch (err) {
      return errorResponse(req, err);
    }
  };
}

const MAX_BODY_BYTES = 64 * 1024;

export async function readJson(req: Request): Promise<unknown> {
  const len = Number(req.headers.get("content-length") ?? "0");
  if (len > MAX_BODY_BYTES) throw new HttpError(413, "payload_too_large", "Requête trop volumineuse");
  const text = await req.text();
  if (text.length > MAX_BODY_BYTES) throw new HttpError(413, "payload_too_large", "Requête trop volumineuse");
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError(400, "invalid_json", "Corps JSON invalide");
  }
}

/** Exécute une tâche après la réponse (Supabase Edge Runtime) ou l'attend. */
export function runInBackground(p: Promise<unknown>): void {
  const safe = p.catch((e) => console.error("background_task_failed", e instanceof Error ? e.message : String(e)));
  // deno-lint-ignore no-explicit-any
  const rt = (globalThis as any).EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(safe);
}
