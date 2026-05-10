import { randomBytes } from 'node:crypto';
import { query } from '../db.js';
import { config } from '../config.js';

export interface SessionRow {
  token: string;
  email: string;
  name: string | null;
  picture: string | null;
  created_at: string;
  last_seen_at: string;
  expires_at: string;
}

/** Generate cryptographically random session token (hex, 64 chars). */
export function newToken(): string {
  return randomBytes(32).toString('hex');
}

export interface CreateSessionOpts {
  email: string;
  name?: string;
  picture?: string;
  ip?: string;
  userAgent?: string;
}

export async function createSession(opts: CreateSessionOpts): Promise<string> {
  const token = newToken();
  const ttl = config.auth.sessionTtlDays;
  await query(
    `INSERT INTO user_session
       (token, email, name, picture, ip, user_agent, expires_at)
     VALUES ($1, $2, $3, $4, $5, $6, NOW() + ($7 || ' days')::interval)`,
    [token, opts.email, opts.name ?? null, opts.picture ?? null,
     opts.ip ?? null, opts.userAgent ?? null, String(ttl)],
  );
  return token;
}

export async function findSession(token: string): Promise<SessionRow | null> {
  if (!token) return null;
  const r = await query<SessionRow>(
    `SELECT token, email, name, picture,
            to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS created_at,
            to_char(last_seen_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS last_seen_at,
            to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS expires_at
       FROM user_session
      WHERE token = $1 AND expires_at > NOW()`,
    [token],
  );
  return r.rows[0] ?? null;
}

export async function touchSession(token: string): Promise<void> {
  await query(`UPDATE user_session SET last_seen_at = NOW() WHERE token = $1`, [token]);
}

export async function destroySession(token: string): Promise<void> {
  await query(`DELETE FROM user_session WHERE token = $1`, [token]);
}

export async function cleanupExpiredSessions(): Promise<number> {
  const r = await query(`DELETE FROM user_session WHERE expires_at < NOW()`);
  return r.rowCount ?? 0;
}

export async function listRecentSessions(limit = 50): Promise<SessionRow[]> {
  const r = await query<SessionRow>(
    `SELECT token, email, name, picture,
            to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS created_at,
            to_char(last_seen_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS last_seen_at,
            to_char(expires_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS expires_at
       FROM user_session
      WHERE expires_at > NOW()
      ORDER BY last_seen_at DESC
      LIMIT $1`,
    [Math.min(Math.max(limit, 1), 200)],
  );
  return r.rows;
}

export async function logAuthEvent(opts: {
  email?: string | null;
  event: 'login_success' | 'login_failed' | 'logout' | 'session_expired';
  reason?: string;
  ip?: string;
  userAgent?: string;
}): Promise<void> {
  await query(
    `INSERT INTO auth_log (email, event, reason, ip, user_agent)
     VALUES ($1, $2, $3, $4, $5)`,
    [opts.email ?? null, opts.event, opts.reason ?? null,
     opts.ip ?? null, opts.userAgent ?? null],
  );
}
