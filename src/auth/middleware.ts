import type { FastifyRequest, FastifyReply } from 'fastify';
import { config } from '../config.js';
import { findSession, touchSession, type SessionRow } from './session.js';

const COOKIE_NAME = 'wrg_session';
export const SESSION_COOKIE = COOKIE_NAME;

/** Extract session token from cookie header (no cookie parser plugin needed). */
export function getSessionTokenFromCookie(req: FastifyRequest): string {
  const header = req.headers.cookie;
  if (!header) return '';
  for (const part of header.split(';')) {
    const [k, v] = part.trim().split('=');
    if (k === COOKIE_NAME) return decodeURIComponent(v ?? '');
  }
  return '';
}

export function buildSessionCookie(token: string, maxAgeSec: number): string {
  const parts = [
    `${COOKIE_NAME}=${token}`,
    'Path=/',
    'HttpOnly',
    'SameSite=Lax',
    `Max-Age=${maxAgeSec}`,
  ];
  // Mark Secure kalau base URL https.
  if (config.auth.baseUrl.startsWith('https://')) parts.push('Secure');
  return parts.join('; ');
}

export function clearCookie(name: string): string {
  return `${name}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0`;
}

export interface AuthContext {
  /** Kalau session login: detail user. */
  session?: SessionRow;
  /** Kalau token-mode (legacy): true tapi tanpa user identity. */
  tokenAuth?: boolean;
}

/**
 * Tries cookie session first, falls back to legacy `DASHBOARD_TOKEN`
 * (header `Authorization: Bearer` atau `?token=...`). Returns the auth
 * context kalau valid, atau null kalau tidak (caller akan 401).
 */
export async function authenticate(req: FastifyRequest): Promise<AuthContext | null> {
  // 1. Cookie session
  const cookieToken = getSessionTokenFromCookie(req);
  if (cookieToken) {
    const sess = await findSession(cookieToken);
    if (sess) {
      // Touch async — don't block the request
      void touchSession(cookieToken);
      return { session: sess };
    }
  }

  // 2. Legacy token (backward compat untuk API calls)
  const expected = config.dashboard.token;
  if (expected) {
    const auth = req.headers.authorization || '';
    const bearer = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
    const q = (req.query as { token?: string } | undefined)?.token ?? '';
    if ((bearer || q) === expected) {
      return { tokenAuth: true };
    }
  }

  return null;
}

/**
 * Fastify guard. Returns true kalau ok (caller continue). Returns false
 * kalau guard already sent response (401/302).
 *
 * `mode='api'`  → return 401 JSON.
 * `mode='page'` → redirect ke /login (untuk navigasi browser).
 */
export async function requireAuth(
  req: FastifyRequest,
  reply: FastifyReply,
  mode: 'api' | 'page' = 'api',
): Promise<AuthContext | null> {
  const ctx = await authenticate(req);
  if (ctx) return ctx;

  if (mode === 'page') {
    reply.redirect('/login?returnTo=' + encodeURIComponent(req.url));
    return null;
  }
  reply.status(401).send({ ok: false, error: 'unauthenticated' });
  return null;
}
