/**
 * Interactive test functions untuk verify integrations.
 * Tiap fungsi return { ok, detail, ...meta } yang user-friendly.
 */

import { config } from '../config.js';
import { sendReply } from '../wa.js';
import { fireAlert } from '../alerts/index.js';
import { sendWeeklyDigestEmail } from '../email/digest.js';
import { lastCompleteWeekRange } from '../email/digest.js';
import { ask, isConfigured as llmConfigured } from '../llm/openrouter.js';

export interface TestResult {
  ok: boolean;
  detail: string;
  meta?: Record<string, unknown>;
}

/** Test WA send: kirim pesan ke target (default group HOD). */
export async function testWaSend(target?: string): Promise<TestResult> {
  const to = target ? 'dm' : 'group';
  const tgt = target || config.wa.hodGroupId;
  const sent = await sendReply({
    to: to as 'dm' | 'group',
    target: tgt,
    text: `🧪 *Test message dari WRG CRM*\nWaktu: ${new Date().toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })}\nMode: ${config.wa.sendMode}\n\nKalau pesan ini sampai, gateway WA sudah berfungsi.`,
  });
  return {
    ok: sent.delivered,
    detail: sent.delivered
      ? `Sent to ${to.toUpperCase()}:${tgt} (mode=${config.wa.sendMode}${sent.attempts ? ', attempts=' + sent.attempts : ''})`
      : `Failed: ${sent.error || 'unknown'}`,
    meta: { mode: config.wa.sendMode, target: tgt, attempts: sent.attempts, messageId: sent.messageId },
  };
}

/** Fire test alert ke semua channel. */
export async function testAlertChannels(): Promise<TestResult> {
  const a = await fireAlert({
    kind: 'test',
    level: 'info',
    title: 'Test alert dari /setup',
    body: `Test trigger pada ${new Date().toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })} WIB. Kalau alert ini sampai, channel berfungsi.`,
    payload: { test: true },
  });
  const channels = a.channels_delivered.map((c) => `${c.channel}=${c.delivered ? '✓' : '✗ ' + (c.error || '')}`).join(', ');
  const allOk = a.channels_delivered.every((c) => c.delivered);
  return {
    ok: allOk,
    detail: `Fired alert #${a.id}: ${channels}`,
    meta: { alertId: a.id, channels: a.channels_delivered },
  };
}

/** Send test email digest (dry-run kalau EMAIL_ENABLED=false). */
export async function testEmailDigest(): Promise<TestResult> {
  const range = lastCompleteWeekRange();
  const recipients = config.email.hodRecipients;
  if (recipients.length === 0) {
    return {
      ok: false,
      detail: 'EMAIL_HOD_RECIPIENTS kosong — set dulu di .env',
    };
  }
  const mode = config.email.enabled ? 'smtp' : 'json';
  const r = await sendWeeklyDigestEmail({ range, transportMode: mode });
  return {
    ok: r.sent,
    detail: r.sent
      ? `Sent to ${r.recipients.length} recipient(s) via ${mode}${r.messageId ? ` • messageId=${r.messageId}` : ''}`
      : `Failed: ${r.error}`,
    meta: { mode, recipients: r.recipients, range: r.range, messageId: r.messageId },
  };
}

/** Test LLM: kirim prompt sederhana, ukur latency + biaya. */
export async function testLlm(): Promise<TestResult> {
  if (!llmConfigured()) {
    return { ok: false, detail: 'OPENROUTER_API_KEY kosong di .env' };
  }
  const r = await ask({
    system: 'Reply ringkas dalam Bahasa Indonesia.',
    user: 'Halo, dari WRG CRM. Sebut nama model kamu dalam 1 kalimat.',
    maxTokens: 80,
  });
  return {
    ok: r.ok,
    detail: r.ok
      ? `${r.model} • ${r.latencyMs}ms • ${r.usage?.total_tokens ?? '?'} tokens • "${r.text.slice(0, 100)}"`
      : `Failed: ${r.error}`,
    meta: { model: r.model, latencyMs: r.latencyMs, usage: r.usage, response: r.text },
  };
}

/** Verify OAuth config tanpa actually login. */
export function testOAuthConfig(): TestResult {
  if (!config.auth.googleClientId || !config.auth.googleClientSecret) {
    return {
      ok: false,
      detail: 'OAUTH_GOOGLE_CLIENT_ID / OAUTH_GOOGLE_CLIENT_SECRET belum di-set',
    };
  }
  if (!config.auth.baseUrl.startsWith('http')) {
    return { ok: false, detail: 'OAUTH_BASE_URL harus http:// atau https://' };
  }
  const issues: string[] = [];
  if (!config.auth.googleHostedDomain && config.auth.emailAllowlist.length === 0) {
    issues.push('⚠️ Tanpa HD dan tanpa allowlist — siapa pun di internet bisa login');
  }
  if (config.auth.baseUrl.startsWith('http://') && !config.auth.baseUrl.includes('localhost')) {
    issues.push('⚠️ OAUTH_BASE_URL pakai HTTP (bukan HTTPS) di non-localhost — cookie tidak Secure');
  }
  return {
    ok: issues.length === 0,
    detail: issues.length === 0
      ? `OK. Redirect URI: ${config.auth.baseUrl}/auth/google/callback`
      : issues.join(' • '),
    meta: {
      clientId: config.auth.googleClientId.slice(0, 12) + '…',
      hd: config.auth.googleHostedDomain || null,
      allowlistSize: config.auth.emailAllowlist.length,
    },
  };
}
