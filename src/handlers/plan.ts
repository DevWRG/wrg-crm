import { query } from '../db.js';
import { bodyAfterHashtag, getField, normalizeTujuan } from '../util/parse.js';
import { formatDateId, parseDmy } from '../util/dateid.js';
import type { HandlerResult, MasterUser } from '../types.js';

interface PlanEntry {
  customer: string;
  tujuan: string;
  goal: string;
  seq: number;
}

const MULTI_LINE_RE = /^(\d+)\s*\|\s*$/m;

function parsePlan(text: string): { tanggal: string; entries: PlanEntry[] } {
  const body = bodyAfterHashtag(text, '#PLAN');
  const tglRaw = getField(body, 'tgl');
  if (!tglRaw) throw new Error('Field "tgl" wajib diisi.');
  const tanggal = parseDmy(tglRaw);

  const multi = body.match(MULTI_LINE_RE);
  if (multi) {
    const expected = parseInt(multi[1], 10);
    const after = body.slice(multi.index! + multi[0].length);
    const lines = after
      .split('\n')
      .map((l) => l.trim())
      .filter((l) => l.length > 0 && l.includes('|'));
    if (lines.length !== expected) {
      throw new Error(
        `Jumlah customer (${lines.length}) tidak sesuai dengan N|=${expected}.`,
      );
    }
    const entries: PlanEntry[] = lines.map((line, idx) => {
      const parts = line.split('|').map((p) => p.trim());
      if (parts.length < 3 || !parts[0]) {
        throw new Error(`Baris ${idx + 1} format salah. Pakai: Customer | tujuan | goal`);
      }
      return {
        customer: parts[0],
        tujuan: normalizeTujuan(parts[1] ?? ''),
        goal: parts.slice(2).join(' | ').trim(),
        seq: idx + 1,
      };
    });
    return { tanggal, entries };
  }

  // SINGLE mode
  const cust = getField(body, 'cust');
  const tujuan = getField(body, 'tujuan');
  const goal = getField(body, 'goal');
  if (!cust) throw new Error('Field "cust" wajib diisi.');
  return {
    tanggal,
    entries: [
      {
        customer: cust,
        tujuan: normalizeTujuan(tujuan ?? ''),
        goal: goal ?? '',
        seq: 1,
      },
    ],
  };
}

export async function handlePlan(user: MasterUser, text: string): Promise<HandlerResult> {
  const { tanggal, entries } = parsePlan(text);

  for (const e of entries) {
    await query(
      `INSERT INTO sales_plan (user_id, tanggal, customer_name, tujuan, goal, seq)
       VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (user_id, tanggal, customer_name)
       DO UPDATE SET tujuan = EXCLUDED.tujuan, goal = EXCLUDED.goal, seq = EXCLUDED.seq`,
      [user.id, tanggal, e.customer, e.tujuan, e.goal, e.seq],
    );
  }

  const lines = entries.map((e, i) => `  ${i + 1}. ${e.customer} — ${e.tujuan || '-'}`).join('\n');
  const reply =
    `✅ *#PLAN diterima!*\n` +
    `👤 ${user.nama_am}  |  📅 ${formatDateId(tanggal)}\n\n` +
    `📋 ${entries.length} customer:\n${lines}\n\n` +
    `Semangat kunjungan hari ini! 💪`;

  return {
    status: 'SUCCESS',
    customerCount: entries.length,
    payload: { tanggal, entries },
    replies: [{ to: 'group', target: '', text: reply }],
  };
}
