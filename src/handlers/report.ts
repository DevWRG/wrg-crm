import { query } from '../db.js';
import { bodyAfterHashtag, getField, splitByDashes, truncate } from '../util/parse.js';
import { formatDateId, parseDmy, todayWib } from '../util/dateid.js';
import type { HandlerResult, MasterUser } from '../types.js';

interface ReportEntry {
  customer: string;
  hasil: string;
  next: string;
  pipelineId: number | null;
}

async function findPipelineId(userId: number, name: string): Promise<number | null> {
  const res = await query<{ id: number }>(
    `SELECT id FROM pipeline_tracker
      WHERE user_id = $1
        AND similarity(customer_name, $2) > 0.3
      ORDER BY similarity(customer_name, $2) DESC
      LIMIT 1`,
    [userId, name],
  );
  return res.rows[0]?.id ?? null;
}

function parseSection(section: string): { customer: string; hasil: string; next: string } {
  const customer = getField(section, 'cust');
  const hasil = getField(section, 'hasil');
  const next = getField(section, 'next');
  if (!customer) throw new Error('Field "cust" wajib diisi di setiap entry.');
  return {
    customer,
    hasil: hasil ?? '',
    next: next ?? '',
  };
}

export async function handleReport(user: MasterUser, text: string): Promise<HandlerResult> {
  const body = bodyAfterHashtag(text, '#REPORT');
  const tglRaw = getField(body, 'tgl');
  const hasDashes = /^\s*---+\s*$/m.test(body);

  let tanggal: string;
  let sections: string[];

  if (tglRaw && hasDashes) {
    // MODE B
    tanggal = parseDmy(tglRaw);
    const afterTgl = body.replace(/^\s*tgl\s*:.*$/im, '').trim();
    sections = splitByDashes(afterTgl);
    if (sections.length === 0) throw new Error('Tidak ada entry setelah separator "---".');
  } else {
    // MODE A
    tanggal = todayWib();
    sections = [body];
  }

  const entries: ReportEntry[] = [];
  for (const sec of sections) {
    const parsed = parseSection(sec);
    const pipelineId = await findPipelineId(user.id, parsed.customer);
    entries.push({ ...parsed, pipelineId });
  }

  for (const e of entries) {
    await query(
      `INSERT INTO activity_log
         (user_id, pipeline_id, customer_name, tanggal, hasil, next_action, source)
       VALUES ($1, $2, $3, $4, $5, $6, '#REPORT')`,
      [user.id, e.pipelineId, e.customer, tanggal, e.hasil, e.next],
    );
  }

  const lines = entries.map((e) => `  • ${e.customer}: ${truncate(e.hasil || '-')}`).join('\n');
  const reply =
    `✅ *#REPORT diterima!*\n` +
    `👤 ${user.nama_am}  |  📅 ${formatDateId(tanggal)}  |  ${entries.length} kunjungan\n\n` +
    `${lines}`;

  return {
    status: 'SUCCESS',
    customerCount: entries.length,
    payload: { tanggal, entries },
    replies: [{ to: 'group', target: '', text: reply }],
  };
}
