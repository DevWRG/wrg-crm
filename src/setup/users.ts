import { query } from '../db.js';

export interface AmRow {
  id: number;
  wa_number: string;
  nama_am: string;
  area: string | null;
  role: string;
  aktif: boolean;
  created_at: string;
  visits_30d: number;
  last_activity_at: string | null;
}

export async function listAms(): Promise<AmRow[]> {
  const r = await query<AmRow>(
    `SELECT mu.id, mu.wa_number, mu.nama_am, mu.area, mu.role, mu.aktif,
            to_char(mu.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS created_at,
            COALESCE(s.n, 0)::int AS visits_30d,
            to_char(s.last_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS last_activity_at
       FROM master_user mu
       LEFT JOIN (
         SELECT user_id,
                COUNT(*)::int AS n,
                MAX(created_at) AS last_at
           FROM activity_log
          WHERE created_at > NOW() - INTERVAL '30 days'
          GROUP BY user_id
       ) s ON s.user_id = mu.id
      ORDER BY mu.aktif DESC, s.n DESC NULLS LAST, mu.nama_am ASC`,
  );
  return r.rows;
}

export interface CreateAmInput {
  wa_number: string;
  nama_am: string;
  area?: string;
  role?: string;
}

const WA_RE = /^[0-9]{8,15}$/;

export function validateAmInput(input: CreateAmInput): string | null {
  if (!input.wa_number || !WA_RE.test(input.wa_number)) {
    return 'wa_number harus 8-15 digit angka tanpa "+" atau spasi (contoh: 6281234567890)';
  }
  if (!input.nama_am || input.nama_am.trim().length < 2) {
    return 'nama_am wajib (minimal 2 karakter)';
  }
  if (input.role && !['AM', 'OSP', 'ADMIN'].includes(input.role)) {
    return 'role harus salah satu: AM, OSP, ADMIN';
  }
  return null;
}

export async function createAm(input: CreateAmInput): Promise<AmRow | { error: string }> {
  const err = validateAmInput(input);
  if (err) return { error: err };

  try {
    await query(
      `INSERT INTO master_user (wa_number, nama_am, area, role, aktif)
       VALUES ($1, $2, $3, $4, TRUE)`,
      [input.wa_number, input.nama_am.trim(), input.area?.trim() || null, input.role || 'AM'],
    );
  } catch (e) {
    const msg = (e as Error).message;
    if (/duplicate key/i.test(msg)) return { error: `wa_number ${input.wa_number} sudah terdaftar` };
    return { error: msg };
  }

  const r = await query<AmRow>(
    `SELECT mu.id, mu.wa_number, mu.nama_am, mu.area, mu.role, mu.aktif,
            to_char(mu.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS created_at,
            0::int AS visits_30d, NULL::text AS last_activity_at
       FROM master_user mu WHERE wa_number = $1`,
    [input.wa_number],
  );
  return r.rows[0];
}

export async function toggleAmAktif(id: number, aktif: boolean): Promise<{ ok: boolean; error?: string }> {
  const r = await query(`UPDATE master_user SET aktif = $1 WHERE id = $2`, [aktif, id]);
  if (r.rowCount === 0) return { ok: false, error: 'AM dengan id ini tidak ditemukan' };
  return { ok: true };
}
