import { query } from '../db.js';
import type { SentReply } from '../wa.js';

export type DeliverySource = 'inbound' | 'scheduler' | 'manual' | 'resend';

export interface DeliveryLogEntry {
  auditId: number | null;
  source: DeliverySource;
  messageIdIn: string | null;
  waNumber: string | null;
  sent: SentReply;
  parentDeliveryId?: number | null;
}

const PREVIEW_LEN = 200;

function truncatePreview(text: string): string {
  return text.length > PREVIEW_LEN ? text.slice(0, PREVIEW_LEN) + '…' : text;
}

export async function writeDelivery(entry: DeliveryLogEntry): Promise<number> {
  const { sent } = entry;
  const r = await query<{ id: number }>(
    `INSERT INTO delivery_log
       (audit_id, source, message_id_in, wa_number,
        to_kind, target, text_preview, text_full,
        delivered, attempts, message_id_out, error, parent_delivery_id)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
     RETURNING id`,
    [
      entry.auditId,
      entry.source,
      entry.messageIdIn,
      entry.waNumber,
      sent.to,
      sent.target,
      truncatePreview(sent.text),
      sent.text,
      sent.delivered,
      sent.attempts ?? 1,
      sent.messageId ?? null,
      sent.error ?? null,
      entry.parentDeliveryId ?? null,
    ],
  );
  return r.rows[0].id;
}

/** Bulk-write deliveries — one INSERT per row, but parallel-safe. */
export async function writeDeliveries(entries: DeliveryLogEntry[]): Promise<number[]> {
  return Promise.all(entries.map(writeDelivery));
}

export interface DeliveryRow {
  id: number;
  audit_id: number | null;
  source: DeliverySource;
  message_id_in: string | null;
  wa_number: string | null;
  to_kind: string;
  target: string;
  text_preview: string | null;
  delivered: boolean;
  attempts: number;
  message_id_out: string | null;
  error: string | null;
  created_at: string;
}

export async function listDeliveries(opts: {
  status?: 'all' | 'failed' | 'success';
  since?: string; // ISO timestamp
  limit?: number;
}): Promise<DeliveryRow[]> {
  const status = opts.status ?? 'all';
  const limit = Math.min(Math.max(opts.limit ?? 100, 1), 500);
  const conds: string[] = [];
  const params: unknown[] = [];
  if (status === 'failed') conds.push(`delivered = FALSE`);
  if (status === 'success') conds.push(`delivered = TRUE`);
  if (opts.since) {
    params.push(opts.since);
    conds.push(`created_at >= $${params.length}::timestamptz`);
  }
  params.push(limit);
  const where = conds.length ? `WHERE ${conds.join(' AND ')}` : '';
  const sql = `
    SELECT id, audit_id, source, message_id_in, wa_number,
           to_kind, target, text_preview, delivered, attempts,
           message_id_out, error,
           to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS created_at
      FROM delivery_log
      ${where}
     ORDER BY created_at DESC
     LIMIT $${params.length}`;
  const r = await query<DeliveryRow>(sql, params);
  return r.rows;
}
