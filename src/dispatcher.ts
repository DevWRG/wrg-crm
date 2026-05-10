import { findUserByWa } from './repo/users.js';
import { writeAudit } from './repo/audit.js';
import { claimMessage, finishMessage } from './repo/dedupe.js';
import { writeDeliveries } from './repo/delivery.js';
import { isExempt, perWaLimiter } from './limiters.js';
import { handlePlan } from './handlers/plan.js';
import { handleReport } from './handlers/report.js';
import { handleLeads } from './handlers/leads.js';
import { handleUpdate, tryHandleConfirmReply } from './handlers/update.js';
import { resolveTarget, sendReply, type SentReply } from './wa.js';
import type { HandlerResult, Hashtag, InboundMessage } from './types.js';

const COMMANDS: Hashtag[] = ['#PLAN', '#REPORT', '#LEADS', '#UPDATE'];

function detectHashtag(text: string): Hashtag | null {
  const m = text.trim().match(/^#(\w+)/);
  if (!m) return null;
  const tag = `#${m[1].toUpperCase()}` as Hashtag;
  return COMMANDS.includes(tag) ? tag : null;
}

function errorReplyText(hashtag: string, message: string): string {
  const examples: Record<string, string> = {
    '#PLAN':
      `Contoh format yang benar:\n#PLAN\n` +
      `tgl: 01/05/2026\ncust: RS Husada Utama\ntujuan: Kunjungan Fisik\ngoal: Demo alat USG seri 500`,
    '#REPORT':
      `Contoh format yang benar:\n#REPORT\n` +
      `cust: RS Husada Utama\nhasil: Sudah demo, dokter tertarik\nnext: Follow-up minggu depan`,
    '#LEADS':
      `Contoh format yang benar:\n#LEADS\n` +
      `cust: RS Sehat Sentosa\npic: dr. Andi (08123456789)\ntipe: RS\nproduk: USG Seri 500\ninfo: Referal dari distributor`,
    '#UPDATE':
      `Contoh format yang benar:\n#UPDATE\n` +
      `cust: RS Husada\nstage: 3\nstatus: Hot\nnote: Sudah deal harga, tunggu PO`,
  };
  return `❌ *${hashtag} Error: ${message}*\n\n${examples[hashtag] ?? ''}`.trim();
}

export interface ProcessOutcome {
  ignored: boolean;
  hashtag?: string;
  result?: HandlerResult;
  sent: SentReply[];
  /** True bila messageId ini sudah pernah di-proses → request di-skip. */
  duplicate?: boolean;
  /** Status entri sebelumnya dari processed_message (hanya saat duplicate=true). */
  originalStatus?: string;
  /** True bila pengirim melebihi kuota per-WA. Server akan balas 429. */
  rateLimited?: boolean;
  retryAfterSec?: number;
}

export async function processInbound(msg: InboundMessage): Promise<ProcessOutcome> {
  const text = msg.text ?? '';
  const ctx = { senderWa: msg.from, sourceGroupId: msg.groupId ?? null };

  // Step -1: rate limit per-WA (kecuali nomor exempt seperti Husni).
  if (!isExempt(msg.from)) {
    const rl = perWaLimiter.check(msg.from);
    if (!rl.allowed) {
      await writeAudit({
        waNumber: msg.from,
        namaAm: null,
        hashtag: 'RATE',
        status: 'RATE_LIMITED',
        customerCount: 0,
        payload: { retryAfterSec: rl.retryAfterSec, limit: rl.limit },
      });
      return {
        ignored: true,
        rateLimited: true,
        retryAfterSec: rl.retryAfterSec,
        sent: [],
      };
    }
  }

  // Step 0: idempotency — skip kalau messageId sudah pernah di-proses.
  if (msg.messageId) {
    const claim = await claimMessage(msg.messageId, msg.from);
    if (!claim.claimed) {
      return {
        ignored: true,
        duplicate: true,
        originalStatus: claim.existing?.status,
        sent: [],
      };
    }
  }

  // Step 1: identify user
  const user = await findUserByWa(msg.from);

  // Pre-empt: confirm replies (UPDATE 1/2/3) — needs user to be registered
  if (user) {
    const confirmRes = await tryHandleConfirmReply(user, text);
    if (confirmRes) {
      const auditId = await writeAudit({
        waNumber: msg.from,
        namaAm: user.nama_am,
        hashtag: '#UPDATE',
        status: confirmRes.status,
        customerCount: confirmRes.customerCount,
        payload: confirmRes.payload,
        errorDetail: confirmRes.error,
      });
      const sent = await Promise.all(
        confirmRes.replies.map((r) => sendReply(resolveTarget(r, ctx))),
      );
      await writeDeliveries(
        sent.map((s) => ({
          auditId,
          source: 'inbound',
          messageIdIn: msg.messageId ?? null,
          waNumber: msg.from,
          sent: s,
        })),
      );
      if (msg.messageId) {
        await finishMessage(msg.messageId, '#UPDATE', confirmRes.status, {
          confirmReply: true,
          deliveredAll: sent.every((s) => s.delivered),
        });
      }
      return { ignored: false, hashtag: '#UPDATE', result: confirmRes, sent };
    }
  }

  // Step 2: detect command
  const hashtag = detectHashtag(text);
  if (!hashtag) {
    if (msg.messageId) await finishMessage(msg.messageId, null, 'IGNORED', {});
    return { ignored: true, sent: [] };
  }

  // User must be registered
  if (!user) {
    const auditId = await writeAudit({
      waNumber: msg.from,
      namaAm: null,
      hashtag,
      status: 'UNREGISTERED',
      customerCount: 0,
      payload: { text },
    });
    const sent = await sendReply(
      resolveTarget(
        { to: 'dm', target: '', text: '❌ Nomor kamu belum terdaftar di WRG CRM. Hubungi Husni.' },
        ctx,
      ),
    );
    await writeDeliveries([
      { auditId, source: 'inbound', messageIdIn: msg.messageId ?? null, waNumber: msg.from, sent },
    ]);
    if (msg.messageId) {
      await finishMessage(msg.messageId, hashtag, 'UNREGISTERED', { delivered: sent.delivered });
    }
    return { ignored: false, hashtag, sent: [sent] };
  }

  // Step 3 + 4: parse + write
  let result: HandlerResult;
  try {
    switch (hashtag) {
      case '#PLAN':
        result = await handlePlan(user, text);
        break;
      case '#REPORT':
        result = await handleReport(user, text);
        break;
      case '#LEADS':
        result = await handleLeads(user, text);
        break;
      case '#UPDATE':
        result = await handleUpdate(user, text);
        break;
    }
  } catch (err) {
    const message = (err as Error).message || 'Unknown error';
    const auditId = await writeAudit({
      waNumber: msg.from,
      namaAm: user.nama_am,
      hashtag,
      status: 'FAILED',
      customerCount: 0,
      payload: { text },
      errorDetail: message,
    });
    const sent = await sendReply(
      resolveTarget(
        { to: 'dm', target: '', text: errorReplyText(hashtag, message) },
        ctx,
      ),
    );
    await writeDeliveries([
      { auditId, source: 'inbound', messageIdIn: msg.messageId ?? null, waNumber: msg.from, sent },
    ]);
    if (msg.messageId) {
      await finishMessage(msg.messageId, hashtag, 'FAILED', { error: message });
    }
    return { ignored: false, hashtag, sent: [sent] };
  }

  // Step 5: audit + reply
  const auditId = await writeAudit({
    waNumber: msg.from,
    namaAm: user.nama_am,
    hashtag,
    status: result.status,
    customerCount: result.customerCount,
    payload: result.payload,
    errorDetail: result.error,
  });
  const sent = await Promise.all(
    result.replies.map((r) => sendReply(resolveTarget(r, ctx))),
  );
  await writeDeliveries(
    sent.map((s) => ({
      auditId,
      source: 'inbound',
      messageIdIn: msg.messageId ?? null,
      waNumber: msg.from,
      sent: s,
    })),
  );
  if (msg.messageId) {
    await finishMessage(msg.messageId, hashtag, result.status, {
      customerCount: result.customerCount,
      replyCount: sent.length,
      deliveredAll: sent.every((s) => s.delivered),
    });
  }
  return { ignored: false, hashtag, result, sent };
}
