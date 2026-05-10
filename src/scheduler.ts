import cron from 'node-cron';
import { runDailySummary } from './summary/index.js';
import { cleanupExpired } from './repo/dedupe.js';
import { processResendBatch } from './resend.js';
import { checkExhaustedAndAlert, checkAndEscalate } from './alerts/index.js';
import { sendWeeklyDigestEmail, recordDigestSend } from './email/digest.js';
import { cleanupExpiredSessions } from './auth/session.js';
import { config } from './config.js';

/**
 * Mulai scheduler. Tiga cron:
 *   1. Daily summary    → 18:00 WIB, Senin–Sabtu
 *   2. Dedupe cleanup   → 02:00 WIB, setiap hari
 *   3. Resend failures  → setiap 5 menit
 *
 * Cron format: "min hour day month dow" (dow: 0=Sun, 1=Mon, …, 6=Sat).
 * Timezone diambil dari config.tz (default Asia/Jakarta).
 */
export function startScheduler(logger: {
  info: (...a: unknown[]) => void;
  warn: (...a: unknown[]) => void;
  error: (...a: unknown[]) => void;
}) {
  const summaryExpr = '0 18 * * 1-6';
  cron.schedule(
    summaryExpr,
    async () => {
      try {
        const r = await runDailySummary();
        logger.info(
          { tanggal: r.tanggal, sentTo: r.sent.target, delivered: r.sent.delivered },
          'daily summary sent',
        );
      } catch (err) {
        logger.error(err, 'daily summary failed');
      }
    },
    { timezone: config.tz },
  );

  const cleanupExpr = '0 2 * * *';
  cron.schedule(
    cleanupExpr,
    async () => {
      try {
        const n = await cleanupExpired();
        const sessionsN = await cleanupExpiredSessions();
        logger.info({ dedupeRowsDeleted: n, sessionsDeleted: sessionsN }, 'nightly cleanup');
      } catch (err) {
        logger.error(err, 'nightly cleanup failed');
      }
    },
    { timezone: config.tz },
  );

  const resendExpr = '*/5 * * * *';
  cron.schedule(
    resendExpr,
    async () => {
      try {
        const r = await processResendBatch();
        if (r.picked > 0) {
          logger.info({ ...r }, 'resend batch processed');
        }
        // Setelah batch (sukses/gagal), evaluasi alert state.
        const a = await checkExhaustedAndAlert();
        if (a.fired) {
          logger.info({ kind: a.alert?.kind, level: a.alert?.level }, 'alert fired');
        }
        // Cek apakah ada warn yang sudah aged tapi belum di-escalate.
        const esc = await checkAndEscalate();
        if (esc.escalated > 0) {
          logger.warn({ escalated: esc.escalated }, 'alerts escalated');
        }
      } catch (err) {
        logger.error(err, 'resend batch or alert check failed');
      }
    },
    { timezone: config.tz },
  );

  // Email digest cron — only register kalau email enabled AND ada recipients.
  const emailReady = config.email.enabled && config.email.hodRecipients.length > 0;
  if (emailReady) {
    cron.schedule(
      config.email.digestCron,
      async () => {
        try {
          const r = await sendWeeklyDigestEmail();
          await recordDigestSend(r);
          logger.info(
            { sent: r.sent, recipients: r.recipients.length, range: r.range, error: r.error },
            'weekly digest email',
          );
        } catch (err) {
          logger.error(err, 'weekly digest email failed');
        }
      },
      { timezone: config.tz },
    );
  }

  logger.info(
    {
      summaryCron: summaryExpr,
      cleanupCron: cleanupExpr,
      resendCron: resendExpr,
      digestCron: emailReady ? config.email.digestCron : 'disabled',
      tz: config.tz,
    },
    'scheduler started',
  );
}
