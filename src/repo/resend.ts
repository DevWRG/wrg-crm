import pg from 'pg';
import { withTx, query } from '../db.js';
import { config } from '../config.js';

export interface ResendCandidate {
  id: number;
  audit_id: number | null;
  message_id_in: string | null;
  wa_number: string | null;
  to_kind: 'group' | 'dm';
  target: string;
  text_full: string;
  resend_count: number;
}

/**
 * Claim a batch of failed deliveries for resend in a single TX. Uses
 * `FOR UPDATE SKIP LOCKED` so multiple concurrent workers can run safely
 * without picking the same row.
 *
 * Eligibility filter:
 *  - delivered = false AND resolved = false
 *  - resend_count < RESEND_MAX_ATTEMPTS
 *  - last_resend_at IS NULL OR last_resend_at < NOW() - backoff
 *  - created_at > NOW() - ttl  (don't resurrect ancient failures)
 *  - source != 'resend'        (only retry originals, not other retries)
 */
export async function claimResendBatch(): Promise<ResendCandidate[]> {
  const max = config.resend.maxAttempts;
  const backoffMin = config.resend.backoffMin;
  const ttlHours = config.resend.ttlHours;
  const batchSize = config.resend.batchSize;

  return withTx(async (client: pg.PoolClient) => {
    const sel = await client.query<ResendCandidate>(
      `SELECT id, audit_id, message_id_in, wa_number,
              to_kind, target, text_full, resend_count
         FROM delivery_log
        WHERE delivered = FALSE
          AND resolved  = FALSE
          AND source   <> 'resend'
          AND resend_count < $1
          AND (last_resend_at IS NULL
               OR last_resend_at < NOW() - ($2 || ' minutes')::interval)
          AND created_at > NOW() - ($3 || ' hours')::interval
        ORDER BY created_at ASC
        LIMIT $4
        FOR UPDATE SKIP LOCKED`,
      [max, String(backoffMin), String(ttlHours), batchSize],
    );
    if (sel.rowCount === 0) return [];
    const ids = sel.rows.map((r) => r.id);
    await client.query(
      `UPDATE delivery_log
          SET resend_count   = resend_count + 1,
              last_resend_at = NOW()
        WHERE id = ANY($1::int[])`,
      [ids],
    );
    return sel.rows.map((r) => ({ ...r, to_kind: r.to_kind as 'group' | 'dm' }));
  });
}

export async function markResolved(id: number): Promise<void> {
  await query(`UPDATE delivery_log SET resolved = TRUE WHERE id = $1`, [id]);
}

export interface ResendStats {
  pending: number;
  resolved24h: number;
  exhausted: number; // hit max attempts without success
}

export async function getResendStats(): Promise<ResendStats> {
  const r = await query<{
    pending: number;
    resolved24h: number;
    exhausted: number;
  }>(
    `SELECT
       COUNT(*) FILTER (
         WHERE delivered = FALSE AND resolved = FALSE
           AND resend_count < $1
           AND created_at > NOW() - ($2 || ' hours')::interval
       )::int AS pending,
       COUNT(*) FILTER (
         WHERE resolved = TRUE
           AND created_at > NOW() - INTERVAL '24 hours'
       )::int AS "resolved24h",
       COUNT(*) FILTER (
         WHERE delivered = FALSE AND resolved = FALSE
           AND resend_count >= $1
       )::int AS exhausted
       FROM delivery_log`,
    [config.resend.maxAttempts, String(config.resend.ttlHours)],
  );
  return r.rows[0] ?? { pending: 0, resolved24h: 0, exhausted: 0 };
}
