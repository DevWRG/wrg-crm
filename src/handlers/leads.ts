import { query } from '../db.js';
import { bodyAfterHashtag, getField } from '../util/parse.js';
import type { HandlerResult, MasterUser } from '../types.js';

export async function handleLeads(user: MasterUser, text: string): Promise<HandlerResult> {
  const body = bodyAfterHashtag(text, '#LEADS');
  const cust = getField(body, 'cust');
  const pic = getField(body, 'pic');
  const tipe = getField(body, 'tipe');
  const produk = getField(body, 'produk');
  const info = getField(body, 'info');

  const missing: string[] = [];
  if (!cust) missing.push('cust');
  if (!pic) missing.push('pic');
  if (!tipe) missing.push('tipe');
  if (!produk) missing.push('produk');
  if (!info) missing.push('info');
  if (missing.length) {
    throw new Error(`Field wajib belum diisi: ${missing.join(', ')}.`);
  }

  const dup = await query<{ id: number; customer_name: string }>(
    `SELECT id, customer_name FROM pipeline_tracker
      WHERE user_id = $1
        AND similarity(customer_name, $2) > 0.6
      ORDER BY similarity(customer_name, $2) DESC
      LIMIT 1`,
    [user.id, cust!],
  );
  const dupRow = dup.rows[0];

  const note = `PIC: ${pic} | Tipe: ${tipe} | ${info}`;
  const ins = await query<{ id: number }>(
    `INSERT INTO pipeline_tracker
       (user_id, customer_name, nama_am, area, produk, stage, status, note)
     VALUES ($1, $2, $3, $4, $5, 1, 'Cold', $6)
     RETURNING id`,
    [user.id, cust, user.nama_am, user.area, produk, note],
  );

  const dupWarn = dupRow ? `\n⚠️ Mirip dengan: ${dupRow.customer_name} (sudah di pipeline)` : '';
  const reply =
    `✅ *Lead baru ditambahkan!*\n` +
    `👤 ${cust}\n` +
    `🏥 ${tipe}  |  📦 ${produk}\n` +
    `📋 Stage 1 — Cold  |  Area: ${user.area ?? '-'}` +
    dupWarn;

  return {
    status: 'SUCCESS',
    customerCount: 1,
    payload: { id: ins.rows[0].id, cust, pic, tipe, produk, info, dup: dupRow ?? null },
    replies: [{ to: 'group', target: '', text: reply }],
  };
}
