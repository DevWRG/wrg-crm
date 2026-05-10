import { query } from '../db.js';

export interface ClaimResult {
  claimed: boolean;
  /** Set when claimed=false. The previously stored row. */
  existing?: {
    status: string;
    hashtag: string | null;
    processed_at: string;
    finished_at: string | null;
    result_summary: unknown;
  };
}

/**
 * Try to claim a `message_id` for processing. Returns `claimed=true` if
 * this is the first time we've seen it; `claimed=false` (with the existing
 * row) if it was already claimed (i.e. a duplicate).
 *
 * Race-safe: relies on the PRIMARY KEY (message_id) constraint and
 * `ON CONFLICT DO NOTHING`. Only one concurrent caller wins the insert.
 */
export async function claimMessage(
  messageId: string,
  waNumber: string,
): Promise<ClaimResult> {
  const ins = await query<{ message_id: string }>(
    `INSERT INTO processed_message (message_id, wa_number, status)
     VALUES ($1, $2, 'PROCESSING')
     ON CONFLICT (message_id) DO NOTHING
     RETURNING message_id`,
    [messageId, waNumber],
  );
  if (ins.rowCount === 1) {
    return { claimed: true };
  }
  const existing = await query<{
    status: string;
    hashtag: string | null;
    processed_at: string;
    finished_at: string | null;
    result_summary: unknown;
  }>(
    `SELECT status, hashtag, processed_at, finished_at, result_summary
       FROM processed_message
      WHERE message_id = $1`,
    [messageId],
  );
  return { claimed: false, existing: existing.rows[0] };
}

/**
 * Mark a previously-claimed message as finished, with hashtag + final status
 * + a small JSON summary (e.g. {customerCount, replyCount, deliveredAll}).
 */
export async function finishMessage(
  messageId: string,
  hashtag: string | null,
  status: string,
  summary: Record<string, unknown>,
): Promise<void> {
  await query(
    `UPDATE processed_message
        SET hashtag = $2,
            status = $3,
            result_summary = $4::jsonb,
            finished_at = NOW()
      WHERE message_id = $1`,
    [messageId, hashtag, status, JSON.stringify(summary)],
  );
}

/** Delete dedupe rows past their TTL. Returns # rows deleted. */
export async function cleanupExpired(): Promise<number> {
  const r = await query(`DELETE FROM processed_message WHERE expires_at < NOW()`);
  return r.rowCount ?? 0;
}
