import { query } from '../db.js';
import { bodyAfterHashtag, getField, normalizeStatus } from '../util/parse.js';
import type { HandlerResult, MasterUser } from '../types.js';

interface Candidate {
  id: number;
  customer_name: string;
  old_stage: number;
  old_status: string;
  score: number;
}

interface UpdatePayload {
  cust: string;
  stage: number;
  status: 'Cold' | 'Warm' | 'Hot' | 'Won' | 'Lost';
  note: string;
}

function parseUpdate(text: string): UpdatePayload {
  const body = bodyAfterHashtag(text, '#UPDATE');
  const cust = getField(body, 'cust');
  const stageRaw = getField(body, 'stage');
  const statusRaw = getField(body, 'status');
  const note = getField(body, 'note') ?? '';

  if (!cust) throw new Error('Field "cust" wajib diisi.');
  if (!stageRaw) throw new Error('Field "stage" wajib diisi (1-5).');
  if (!statusRaw) throw new Error('Field "status" wajib diisi (Cold/Warm/Hot/Won/Lost).');

  const stage = parseInt(stageRaw, 10);
  if (!Number.isInteger(stage) || stage < 1 || stage > 5) {
    throw new Error(`Stage harus angka 1-5, dapat: "${stageRaw}".`);
  }
  const status = normalizeStatus(statusRaw);
  if (!status) throw new Error(`Status tidak dikenal: "${statusRaw}". Pakai Cold/Warm/Hot/Won/Lost.`);

  return { cust, stage, status, note };
}

async function findCandidates(userId: number, name: string): Promise<Candidate[]> {
  const res = await query<Candidate>(
    `SELECT id, customer_name,
            stage AS old_stage, status AS old_status,
            similarity(customer_name, $2) AS score
       FROM pipeline_tracker
      WHERE user_id = $1
        AND similarity(customer_name, $2) > 0.25
      ORDER BY score DESC
      LIMIT 3`,
    [userId, name],
  );
  return res.rows;
}

async function applyUpdate(
  cand: Candidate,
  payload: UpdatePayload,
): Promise<void> {
  await query(
    `UPDATE pipeline_tracker
        SET stage = $1, status = $2, note = $3, updated_at = NOW()
      WHERE id = $4`,
    [payload.stage, payload.status, payload.note, cand.id],
  );
}

export async function handleUpdate(user: MasterUser, text: string): Promise<HandlerResult> {
  const payload = parseUpdate(text);
  const candidates = await findCandidates(user.id, payload.cust);

  if (candidates.length === 0 || candidates[0].score < 0.4) {
    const reply =
      `❌ *"${payload.cust}" tidak ditemukan di pipeline kamu.*\n` +
      `Cek nama customer atau gunakan #LEADS untuk tambah baru.`;
    return {
      status: 'NOT_FOUND',
      customerCount: 0,
      payload: { ...payload, candidates },
      replies: [{ to: 'dm', target: '', text: reply }],
    };
  }

  const top = candidates[0];

  if (top.score >= 0.7) {
    await applyUpdate(top, payload);
    const reply =
      `✅ *Pipeline diupdate!*\n` +
      `👤 ${top.customer_name}\n` +
      `Stage: ${top.old_stage} → ${payload.stage}  |  ${top.old_status} → ${payload.status}\n` +
      `📝 ${payload.note || '-'}`;
    return {
      status: 'SUCCESS',
      customerCount: 1,
      payload: { ...payload, applied: top },
      replies: [{ to: 'group', target: '', text: reply }],
    };
  }

  // CONFIRM mode: store pending and ask via DM
  await query(
    `INSERT INTO pending_confirm (wa_number, hashtag, candidates, payload)
     VALUES ($1, '#UPDATE', $2::jsonb, $3::jsonb)`,
    [user.wa_number, JSON.stringify(candidates), JSON.stringify(payload)],
  );

  const lines = candidates
    .map((c, i) => `  ${i + 1}. ${c.customer_name} (${Math.round(c.score * 100)}% match)`)
    .join('\n');
  const reply =
    `⚠️ *Maksud kamu customer yang mana?*\n\n${lines}\n\n` +
    `Balas: *UPDATE 1*, *UPDATE 2*, atau *UPDATE 3*`;

  return {
    status: 'CONFIRM_NEEDED',
    customerCount: 0,
    payload: { ...payload, candidates },
    replies: [{ to: 'dm', target: '', text: reply }],
  };
}

const CONFIRM_RE = /^\s*update\s+([1-3])\s*$/i;

export async function tryHandleConfirmReply(
  user: MasterUser,
  text: string,
): Promise<HandlerResult | null> {
  const m = text.match(CONFIRM_RE);
  if (!m) return null;
  const choice = parseInt(m[1], 10);

  const pending = await query<{ id: number; candidates: Candidate[]; payload: UpdatePayload }>(
    `SELECT id, candidates, payload FROM pending_confirm
      WHERE wa_number = $1 AND hashtag = '#UPDATE' AND expires_at > NOW()
      ORDER BY created_at DESC LIMIT 1`,
    [user.wa_number],
  );
  const row = pending.rows[0];
  if (!row) {
    return {
      status: 'NOT_FOUND',
      customerCount: 0,
      payload: { choice },
      replies: [
        {
          to: 'dm',
          target: '',
          text: '❌ Tidak ada permintaan #UPDATE yang menunggu konfirmasi (atau sudah expired).',
        },
      ],
    };
  }

  const cand = row.candidates[choice - 1];
  if (!cand) {
    return {
      status: 'FAILED',
      customerCount: 0,
      payload: { choice, candidates: row.candidates },
      replies: [{ to: 'dm', target: '', text: `❌ Pilihan ${choice} tidak tersedia.` }],
      error: 'invalid_choice',
    };
  }

  await applyUpdate(cand, row.payload);
  await query(`DELETE FROM pending_confirm WHERE id = $1`, [row.id]);

  const reply =
    `✅ *Pipeline diupdate!*\n` +
    `👤 ${cand.customer_name}\n` +
    `Stage: ${cand.old_stage} → ${row.payload.stage}  |  ${cand.old_status} → ${row.payload.status}\n` +
    `📝 ${row.payload.note || '-'}`;

  return {
    status: 'SUCCESS',
    customerCount: 1,
    payload: { ...row.payload, applied: cand },
    replies: [{ to: 'group', target: '', text: reply }],
  };
}
