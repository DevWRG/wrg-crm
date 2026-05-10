import dayjs from 'dayjs';
import utc from 'dayjs/plugin/utc.js';
import timezone from 'dayjs/plugin/timezone.js';

import { config } from '../config.js';
import { fetchSummary } from '../summary/queries.js';
import { renderWeeklyDigest } from '../exports/digest.js';
import { formatDateId } from '../util/dateid.js';
import { getTransport } from './transport.js';

dayjs.extend(utc);
dayjs.extend(timezone);

const TZ = 'Asia/Jakarta';

/**
 * Returns Mon-Sun YYYY-MM-DD range of the most recently completed week
 * (anchored to WIB). Saat dipanggil Senin pagi, ini akan jadi Mon-Sun
 * minggu sebelumnya.
 */
export function lastCompleteWeekRange(now: dayjs.Dayjs = dayjs().tz(TZ)): {
  from: string; to: string;
} {
  const today = now.tz(TZ).startOf('day');
  const dow = today.day(); // 0=Sun … 6=Sat
  // Days to subtract to reach most-recent past Sunday. If today is Sunday,
  // we want LAST week's Sunday (7 days back), not today.
  const daysBackToSun = dow === 0 ? 7 : dow;
  const to = today.subtract(daysBackToSun, 'day');
  const from = to.subtract(6, 'day');
  return { from: from.format('YYYY-MM-DD'), to: to.format('YYYY-MM-DD') };
}

interface DigestStats {
  totalVisits: number;
  totalPlans: number;
  totalAmRoster: number;
  activeAmThisWeek: number;
}

async function fetchHeadlineStats(from: string, to: string): Promise<DigestStats> {
  const { query } = await import('../db.js');
  const r = await query<{
    visits: number; plans: number;
    active_am: number; total_am: number;
  }>(
    `WITH am AS (
       SELECT id FROM master_user WHERE aktif = TRUE AND role = 'AM'
     ),
     v AS (
       SELECT COUNT(*)::int AS n, COUNT(DISTINCT user_id)::int AS distinct_am
         FROM activity_log
        WHERE tanggal BETWEEN $1::date AND $2::date
     ),
     p AS (
       SELECT COUNT(*)::int AS n FROM sales_plan
        WHERE tanggal BETWEEN $1::date AND $2::date
     )
     SELECT v.n AS visits, p.n AS plans,
            v.distinct_am AS active_am,
            (SELECT COUNT(*)::int FROM am) AS total_am
       FROM v, p`,
    [from, to],
  );
  const row = r.rows[0];
  return {
    totalVisits: row?.visits ?? 0,
    totalPlans: row?.plans ?? 0,
    activeAmThisWeek: row?.active_am ?? 0,
    totalAmRoster: row?.total_am ?? 0,
  };
}

function plainTextFallback(from: string, to: string, s: DigestStats): string {
  const cov = s.totalPlans > 0 ? Math.round((s.totalVisits / s.totalPlans) * 100) : 0;
  return [
    `WRG Weekly Digest — ${formatDateId(from)} → ${formatDateId(to)}`,
    '',
    `Total Visits     : ${s.totalVisits}`,
    `Total Plans      : ${s.totalPlans}`,
    `Coverage         : ${cov}%`,
    `Active AM (week) : ${s.activeAmThisWeek}/${s.totalAmRoster}`,
    '',
    `Detail lengkap (per-day breakdown, per-AM, deals closed, hot pipeline)`,
    `ada di lampiran HTML — buka di browser, atau Cmd+P untuk Save as PDF.`,
    '',
    `Untuk akses live dashboard, hubungi admin.`,
  ].join('\n');
}

export interface DigestEmailResult {
  sent: boolean;
  recipients: string[];
  subject: string;
  messageId?: string;
  rawJson?: string; // populated when transport is jsonTransport (test mode)
  error?: string;
  range: { from: string; to: string };
}

export interface SendDigestOpts {
  /** Override date range (default: lastCompleteWeekRange()) */
  range?: { from: string; to: string };
  /** Override transport mode for testing (default: respects EMAIL_ENABLED) */
  transportMode?: 'smtp' | 'json';
  /** Override recipients (default: EMAIL_HOD_RECIPIENTS) */
  recipients?: string[];
}

export async function sendWeeklyDigestEmail(opts: SendDigestOpts = {}): Promise<DigestEmailResult> {
  const range = opts.range ?? lastCompleteWeekRange();
  const recipients = opts.recipients ?? config.email.hodRecipients;
  const subject =
    `WRG Weekly Digest — ${formatDateId(range.from)} → ${formatDateId(range.to)}`;

  if (recipients.length === 0) {
    return {
      sent: false,
      recipients: [],
      subject,
      error: 'no recipients configured (EMAIL_HOD_RECIPIENTS empty)',
      range,
    };
  }

  const transport = getTransport(opts.transportMode);
  if (!transport) {
    return {
      sent: false,
      recipients,
      subject,
      error: 'email transport disabled (EMAIL_ENABLED=false or SMTP_HOST missing)',
      range,
    };
  }

  const html = await renderWeeklyDigest(range.from, range.to);
  const stats = await fetchHeadlineStats(range.from, range.to);
  const text = plainTextFallback(range.from, range.to, stats);

  try {
    const info = await transport.sendMail({
      from: config.email.from,
      to: recipients,
      subject,
      html,
      text,
    });

    // jsonTransport returns the JSON message in `info.message` (string).
    const rawJson = typeof (info as { message?: unknown }).message === 'string'
      ? (info as { message: string }).message
      : undefined;

    return {
      sent: true,
      recipients,
      subject,
      messageId: info.messageId,
      rawJson,
      range,
    };
  } catch (err) {
    return {
      sent: false,
      recipients,
      subject,
      error: (err as Error).message,
      range,
    };
  }
}

/** Persist digest send result to email_log audit table. */
export async function recordDigestSend(r: DigestEmailResult): Promise<void> {
  const { query } = await import('../db.js');
  await query(
    `INSERT INTO email_log
       (kind, recipients, subject, range_from, range_to,
        delivered, message_id, error)
     VALUES ('weekly_digest', $1::jsonb, $2, $3, $4, $5, $6, $7)`,
    [
      JSON.stringify(r.recipients),
      r.subject,
      r.range.from,
      r.range.to,
      r.sent,
      r.messageId ?? null,
      r.error ?? null,
    ],
  );
}
