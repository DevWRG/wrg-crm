import { config } from '../config.js';
import { sendReply } from '../wa.js';

export interface AlertMessage {
  kind: string;
  level: 'info' | 'warn' | 'critical';
  title: string;
  body: string;
  payload?: Record<string, unknown>;
}

export interface ChannelResult {
  channel: string;
  delivered: boolean;
  error?: string;
}

export interface AlertChannel {
  name: string;
  enabled(): boolean;
  send(msg: AlertMessage): Promise<ChannelResult>;
}

/** Always-on log channel. Tidak pernah fail. */
export const logChannel: AlertChannel = {
  name: 'log',
  enabled: () => true,
  async send(msg) {
    const tag = `[ALERT ${msg.level.toUpperCase()}]`;
    // eslint-disable-next-line no-console
    console.log(`${tag} ${msg.title}\n${msg.body}`);
    return { channel: 'log', delivered: true };
  },
};

/**
 * HTTP webhook channel. Slack-compatible body shape:
 *   { text: "<title>\n<body>", attachments: [{color, fields:[{title, value}]}] }
 * Set `ALERT_WEBHOOK_URL` di env untuk aktifkan. Bisa diarahkan ke Slack,
 * Discord (perlu /slack suffix), Telegram bot, atau adapter custom.
 */
export const httpWebhookChannel: AlertChannel = {
  name: 'http-webhook',
  enabled: () => Boolean(config.alerts.webhookUrl),
  async send(msg) {
    const color = msg.level === 'critical' ? '#f85149' : msg.level === 'warn' ? '#d29922' : '#58a6ff';
    const fields = Object.entries(msg.payload ?? {})
      .filter(([, v]) => v !== undefined && v !== null)
      .map(([k, v]) => ({ title: k, value: String(v), short: true }));

    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), config.alerts.webhookTimeoutMs);
    try {
      const res = await fetch(config.alerts.webhookUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
          text: `*${msg.title}*\n${msg.body}`,
          attachments: fields.length ? [{ color, fields }] : undefined,
        }),
        signal: ctrl.signal,
      });
      if (!res.ok) {
        return { channel: 'http-webhook', delivered: false, error: `HTTP ${res.status}` };
      }
      return { channel: 'http-webhook', delivered: true };
    } catch (err) {
      return { channel: 'http-webhook', delivered: false, error: (err as Error).message };
    } finally {
      clearTimeout(t);
    }
  },
};

/**
 * Best-effort WhatsApp DM channel. Catatan: kalau gateway WA-nya yang lagi
 * down, channel ini akan gagal — tetap dicoba tapi jangan diandalkan
 * sebagai single source of truth. Selalu pakai bareng channel lain.
 */
export const waDmChannel: AlertChannel = {
  name: 'wa-dm',
  enabled: () => Boolean(config.alerts.waNumber),
  async send(msg) {
    const text = `🚨 *${msg.title}*\n${msg.body}`;
    const sent = await sendReply({ to: 'dm', target: config.alerts.waNumber, text });
    return {
      channel: 'wa-dm',
      delivered: sent.delivered,
      error: sent.delivered ? undefined : sent.error,
    };
  },
};

export const allChannels: AlertChannel[] = [logChannel, httpWebhookChannel, waDmChannel];
