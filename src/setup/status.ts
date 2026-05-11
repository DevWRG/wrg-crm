/**
 * Integration health checks. Tiap fungsi balikin status:
 *   ok=true → green ✓
 *   ok=false + reason → red ✗
 *   ok=null + note  → grey (disabled / not configured)
 */

import { query } from '../db.js';
import { config } from '../config.js';
import { isConfigured as googleConfigured } from '../auth/google.js';
import { isConfigured as llmConfigured } from '../llm/openrouter.js';

export interface CheckResult {
  ok: boolean | null;
  label: string;
  detail: string;
}

export async function checkDb(): Promise<CheckResult> {
  try {
    const r = await query<{ now: string; version: string }>(
      `SELECT NOW()::text AS now, current_setting('server_version') AS version`,
    );
    const tables = await query<{ n: number }>(
      `SELECT COUNT(*)::int AS n FROM information_schema.tables WHERE table_schema = 'public'`,
    );
    return {
      ok: true,
      label: 'PostgreSQL',
      detail: `pg ${r.rows[0]?.version} @ ${config.pg.host}:${config.pg.port}/${config.pg.database} • ${tables.rows[0]?.n} tables`,
    };
  } catch (err) {
    return { ok: false, label: 'PostgreSQL', detail: (err as Error).message };
  }
}

export function checkWaGateway(): CheckResult {
  if (config.wa.sendMode === 'mock') {
    return {
      ok: null,
      label: 'WhatsApp Gateway',
      detail: 'Mode mock — reply hanya log ke stdout, tidak ke WA beneran',
    };
  }
  if (!config.wa.sendUrl) {
    return {
      ok: false,
      label: 'WhatsApp Gateway',
      detail: 'WA_SEND_MODE=http tapi WA_SEND_URL kosong',
    };
  }
  return {
    ok: true,
    label: 'WhatsApp Gateway',
    detail: `${config.wa.sendUrl} (retries=${config.wa.retries}, timeout=${config.wa.timeoutMs}ms)`,
  };
}

export function checkEmail(): CheckResult {
  if (!config.email.enabled) {
    return { ok: null, label: 'Email digest', detail: 'EMAIL_ENABLED=false' };
  }
  if (!config.email.smtpHost) {
    return { ok: false, label: 'Email digest', detail: 'SMTP_HOST kosong' };
  }
  if (config.email.hodRecipients.length === 0) {
    return { ok: false, label: 'Email digest', detail: 'EMAIL_HOD_RECIPIENTS kosong' };
  }
  return {
    ok: true,
    label: 'Email digest',
    detail: `${config.email.smtpHost}:${config.email.smtpPort} → ${config.email.hodRecipients.length} recipient(s) • cron ${config.email.digestCron}`,
  };
}

export function checkAlerts(): CheckResult {
  const channels: string[] = ['log'];
  if (config.alerts.webhookUrl) channels.push('http-webhook');
  if (config.alerts.waNumber) channels.push('wa-dm');
  if (channels.length === 1) {
    return {
      ok: null,
      label: 'Alerts',
      detail: 'Hanya log channel (set ALERT_WEBHOOK_URL atau ALERT_WA_NUMBER untuk Slack/WA)',
    };
  }
  return {
    ok: true,
    label: 'Alerts',
    detail: `${channels.length} channels: ${channels.join(', ')} • debounce ${config.alerts.debounceMin}m • escalate after ${config.alerts.escalateAfterMin}m`,
  };
}

export function checkOAuth(): CheckResult {
  if (!googleConfigured()) {
    return {
      ok: null,
      label: 'Google OAuth',
      detail: 'Belum di-set — login pakai DASHBOARD_TOKEN saja',
    };
  }
  const hd = config.auth.googleHostedDomain;
  const allow = config.auth.emailAllowlist.length;
  const restrict = allow > 0
    ? `${allow} email di allowlist`
    : hd
    ? `HD restricted: @${hd}`
    : '⚠️ TANPA restriction — siapa pun bisa login';
  return {
    ok: true,
    label: 'Google OAuth',
    detail: `redirect: ${config.auth.baseUrl}/auth/google/callback • ${restrict}`,
  };
}

export function checkDashboardToken(): CheckResult {
  if (!config.dashboard.token) {
    return { ok: false, label: 'Dashboard token', detail: 'DASHBOARD_TOKEN kosong — dashboard ditolak semua request' };
  }
  if (config.dashboard.token.length < 16) {
    return {
      ok: false,
      label: 'Dashboard token',
      detail: `Token terlalu pendek (${config.dashboard.token.length} char) — minimal 32 char untuk prod`,
    };
  }
  if (/dev|test|ganti|change|todo/i.test(config.dashboard.token)) {
    return {
      ok: null,
      label: 'Dashboard token',
      detail: `Token kelihatannya dev (${config.dashboard.token.length} char) — ganti sebelum prod`,
    };
  }
  return {
    ok: true,
    label: 'Dashboard token',
    detail: `Set (${config.dashboard.token.length} char)`,
  };
}

export function checkLlm(): CheckResult {
  if (!llmConfigured()) {
    return {
      ok: null,
      label: 'AI / LLM (OpenRouter)',
      detail: 'OPENROUTER_API_KEY kosong — narrative fallback ke template',
    };
  }
  return {
    ok: true,
    label: 'AI / LLM (OpenRouter)',
    detail: `model=${config.llm.model} • timeout=${config.llm.timeoutMs}ms`,
  };
}

export async function checkAll(): Promise<CheckResult[]> {
  const db = await checkDb();
  return [db, checkWaGateway(), checkEmail(), checkAlerts(), checkOAuth(), checkLlm(), checkDashboardToken()];
}
