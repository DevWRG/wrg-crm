import { query } from '../db.js';
import type { MasterUser } from '../types.js';

export async function findUserByWa(wa: string): Promise<MasterUser | null> {
  const res = await query<MasterUser>(
    `SELECT id, wa_number, nama_am, area, role, aktif
       FROM master_user
      WHERE wa_number = $1 AND aktif = TRUE`,
    [wa],
  );
  return res.rows[0] ?? null;
}
