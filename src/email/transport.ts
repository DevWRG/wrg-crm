import nodemailer, { type Transporter } from 'nodemailer';
import { config } from '../config.js';

let cached: Transporter | null = null;
let cachedKind: 'smtp' | 'json' | 'disabled' = 'disabled';

/**
 * Build (or return cached) nodemailer transport.
 *
 *   mode='smtp'     → real SMTP, requires SMTP_HOST.
 *   mode='json'     → dry-run, message disimpan ke result.message (untuk testing).
 *   mode='disabled' → null transport (kalau EMAIL_ENABLED=false dan tidak diminta explicit).
 *
 * Default mengikuti config.email.enabled.
 */
export function getTransport(mode?: 'smtp' | 'json'): Transporter | null {
  const desired = mode ?? (config.email.enabled ? 'smtp' : 'disabled');

  if (cached && cachedKind === desired) return cached;

  if (desired === 'json') {
    cached = nodemailer.createTransport({ jsonTransport: true });
    cachedKind = 'json';
    return cached;
  }

  if (desired === 'disabled') {
    cached = null;
    cachedKind = 'disabled';
    return null;
  }

  // smtp
  if (!config.email.smtpHost) {
    // eslint-disable-next-line no-console
    console.warn('[email] EMAIL_ENABLED=true but SMTP_HOST missing — falling back to disabled.');
    cached = null;
    cachedKind = 'disabled';
    return null;
  }
  cached = nodemailer.createTransport({
    host: config.email.smtpHost,
    port: config.email.smtpPort,
    secure: config.email.smtpSecure,
    auth: config.email.smtpUser
      ? { user: config.email.smtpUser, pass: config.email.smtpPass }
      : undefined,
  });
  cachedKind = 'smtp';
  return cached;
}

export function resetTransport(): void {
  cached = null;
  cachedKind = 'disabled';
}
