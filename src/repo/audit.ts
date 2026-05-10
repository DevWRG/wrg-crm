import { query } from '../db.js';
import type { AuditStatus, Hashtag } from '../types.js';

export interface AuditEntry {
  waNumber: string;
  namaAm: string | null;
  hashtag: Hashtag | string;
  status: AuditStatus;
  customerCount: number;
  payload: Record<string, unknown>;
  errorDetail?: string;
}

export async function writeAudit(entry: AuditEntry): Promise<number> {
  const r = await query<{ id: number }>(
    `INSERT INTO audit_log
       (wa_number, nama_am, hashtag, status, customer_count, payload, error_detail)
     VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7)
     RETURNING id`,
    [
      entry.waNumber,
      entry.namaAm,
      entry.hashtag,
      entry.status,
      entry.customerCount,
      JSON.stringify(entry.payload ?? {}),
      entry.errorDetail ?? null,
    ],
  );
  return r.rows[0].id;
}
