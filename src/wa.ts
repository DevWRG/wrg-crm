/**
 * WhatsApp send abstraction.
 *
 * Default mode = `mock` (logs replies; useful for dev & CI).
 * Set WA_SEND_MODE=http and provide WA_SEND_URL to forward to a real
 * gateway (OpenClaw, Baileys-server, whatsapp-web.js, dsb).
 *
 * ── HTTP CONTRACT ────────────────────────────────────────────────
 * Request:
 *   POST {WA_SEND_URL}
 *   Authorization: Bearer {WA_SEND_TOKEN}    (jika token diset)
 *   Content-Type: application/json
 *   Body: {
 *     "to":     "group" | "dm",   // routing intent
 *     "target": string,           // group id atau wa number
 *     "text":   string            // body pesan (boleh multi-line, markdown WA *bold*)
 *   }
 *
 * Response:
 *   2xx → dianggap delivered. Optional body { "messageId": "..." }
 *         akan ditangkap dan dilog.
 *   4xx → permanent error, TIDAK retry.
 *   5xx / network error / timeout → retry sampai WA_HTTP_RETRIES.
 *
 * Untuk gateway yang format-nya beda, tulis adapter kecil yang
 * menerima format kanonik di atas dan menerjemahkan ke format
 * gateway-mu, lalu arahkan WA_SEND_URL ke adapter tsb.
 */

import { config } from './config.js';
import type { OutboundReply } from './types.js';

export interface SentReply extends OutboundReply {
  delivered: boolean;
  messageId?: string;
  attempts?: number;
  error?: string;
}

const RETRY_BACKOFF_MS = [500, 1500, 3000];

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

async function postOnce(
  reply: OutboundReply,
): Promise<{ ok: boolean; status: number; messageId?: string; error?: string }> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), config.wa.timeoutMs);
  try {
    const res = await fetch(config.wa.sendUrl, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(config.wa.sendToken ? { authorization: `Bearer ${config.wa.sendToken}` } : {}),
      },
      body: JSON.stringify(reply),
      signal: ctrl.signal,
    });
    let messageId: string | undefined;
    try {
      const ct = res.headers.get('content-type') || '';
      if (ct.includes('application/json')) {
        const j = (await res.json()) as { messageId?: string; message_id?: string };
        messageId = j.messageId ?? j.message_id;
      }
    } catch {
      // body parse failed — ignore, status is what matters
    }
    return { ok: res.ok, status: res.status, messageId };
  } catch (err) {
    const message = (err as Error).message || 'fetch failed';
    return { ok: false, status: 0, error: message };
  } finally {
    clearTimeout(t);
  }
}

export async function sendReply(reply: OutboundReply): Promise<SentReply> {
  if (config.wa.sendMode === 'mock') {
    // eslint-disable-next-line no-console
    console.log(
      `\n[WA-MOCK → ${reply.to.toUpperCase()} ${reply.target}]\n${reply.text}\n`,
    );
    return { ...reply, delivered: true, attempts: 0 };
  }

  if (!config.wa.sendUrl) {
    return { ...reply, delivered: false, attempts: 0, error: 'WA_SEND_URL not configured' };
  }

  const maxAttempts = Math.max(1, config.wa.retries + 1);
  let lastError = '';
  let lastStatus = 0;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const r = await postOnce(reply);
    if (r.ok) {
      return { ...reply, delivered: true, messageId: r.messageId, attempts: attempt };
    }
    lastStatus = r.status;
    lastError = r.error ?? `HTTP ${r.status}`;

    // 4xx: permanent — tidak retry.
    if (r.status >= 400 && r.status < 500) break;

    // last attempt: jangan tidur lagi
    if (attempt < maxAttempts) {
      const backoff = RETRY_BACKOFF_MS[Math.min(attempt - 1, RETRY_BACKOFF_MS.length - 1)];
      await sleep(backoff);
    }
  }

  // eslint-disable-next-line no-console
  console.error(
    `[WA-HTTP] failed to deliver after ${maxAttempts} attempts: status=${lastStatus} error=${lastError}`,
  );
  return { ...reply, delivered: false, attempts: maxAttempts, error: lastError };
}

/**
 * Resolve `target` for replies that came back from a handler with empty target.
 * "group" → use config.wa.groupId (or the original sourceGroupId if provided)
 * "dm"    → use the sender's wa_number
 */
export function resolveTarget(
  reply: OutboundReply,
  ctx: { senderWa: string; sourceGroupId?: string | null },
): OutboundReply {
  if (reply.target) return reply;
  if (reply.to === 'group') {
    return { ...reply, target: ctx.sourceGroupId || config.wa.groupId };
  }
  return { ...reply, target: ctx.senderWa };
}
