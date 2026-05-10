import { query } from '../db.js';
import { config } from '../config.js';
import { allChannels, type AlertMessage, type ChannelResult } from './channels.js';

export interface AlertRecord {
  id: number;
  kind: string;
  level: string;
  title: string;
  body: string;
  payload: Record<string, unknown>;
  channels_delivered: ChannelResult[];
  created_at: string;
  escalation_for?: number | null;
  escalated_at?: string | null;
}

/**
 * Kirim alert ke semua channel yang enabled. Tulis hasil ke alert_log.
 * Channel yang gagal tidak block channel lain (Promise.allSettled).
 */
export async function fireAlert(msg: AlertMessage): Promise<AlertRecord> {
  const enabled = allChannels.filter((c) => c.enabled());
  const settled = await Promise.allSettled(enabled.map((c) => c.send(msg)));
  const results: ChannelResult[] = settled.map((s, i) =>
    s.status === 'fulfilled'
      ? s.value
      : { channel: enabled[i].name, delivered: false, error: (s.reason as Error).message },
  );

  const r = await query<AlertRecord>(
    `INSERT INTO alert_log (kind, level, title, body, payload, channels_delivered)
     VALUES ($1, $2, $3, $4, $5::jsonb, $6::jsonb)
     RETURNING id, kind, level, title, body,
               payload, channels_delivered,
               to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS created_at`,
    [
      msg.kind,
      msg.level,
      msg.title,
      msg.body,
      JSON.stringify(msg.payload ?? {}),
      JSON.stringify(results),
    ],
  );
  return r.rows[0];
}

interface ExhaustedSnapshot {
  count: number;
  maxId: number;
  samples: Array<{
    id: number;
    target: string;
    error: string | null;
    resend_count: number;
  }>;
}

/** Snapshot of currently-exhausted (delivered=false, resolved=false, resend_count >= max) deliveries. */
async function snapshotExhausted(): Promise<ExhaustedSnapshot> {
  const r = await query<{
    count: number;
    max_id: number;
  }>(
    `SELECT COUNT(*)::int AS count, COALESCE(MAX(id), 0)::int AS max_id
       FROM delivery_log
      WHERE delivered = FALSE
        AND resolved = FALSE
        AND resend_count >= $1`,
    [config.resend.maxAttempts],
  );
  const samples = await query<{
    id: number;
    target: string;
    error: string | null;
    resend_count: number;
  }>(
    `SELECT id, target, error, resend_count
       FROM delivery_log
      WHERE delivered = FALSE
        AND resolved = FALSE
        AND resend_count >= $1
      ORDER BY id DESC
      LIMIT 5`,
    [config.resend.maxAttempts],
  );
  return {
    count: r.rows[0]?.count ?? 0,
    maxId: r.rows[0]?.max_id ?? 0,
    samples: samples.rows,
  };
}

/**
 * Check & alert pada exhausted-resend state. Logic:
 *
 *   1. Hitung exhausted sekarang. Jika 0 → tidak ada alert (kembali clear).
 *   2. Cari alert exhausted_resend terakhir.
 *   3. Kalau ada exhausted baru (maxId sekarang > maxId terakhir di-alert)
 *      DAN sudah lewat debounce window → fire alert dengan watermark baru.
 *   4. Kalau sebelumnya pernah alert tapi sekarang clear → fire 'cleared' info.
 */
export async function checkExhaustedAndAlert(): Promise<{
  fired: boolean;
  alert?: AlertRecord;
  reason: string;
}> {
  const snap = await snapshotExhausted();

  const last = await query<{
    id: number;
    max_id: number;
    created_at: string;
  }>(
    `SELECT id,
            COALESCE((payload->>'maxId')::int, 0) AS max_id,
            created_at
       FROM alert_log
      WHERE kind = 'exhausted_resend'
      ORDER BY created_at DESC
      LIMIT 1`,
  );
  const lastRow = last.rows[0];
  const lastMaxId = lastRow?.max_id ?? 0;
  const debounceMs = config.alerts.debounceMin * 60_000;
  const sinceLastMs = lastRow ? Date.now() - new Date(lastRow.created_at).getTime() : Infinity;

  // Case A: nothing exhausted right now.
  if (snap.count === 0) {
    // Auto-clear: fire info 'cleared' once if last alert was an exhausted_resend.
    if (lastRow) {
      // Check that we haven't already fired a 'cleared' newer than 'exhausted_resend'.
      const clearedNewer = await query<{ id: number }>(
        `SELECT id FROM alert_log
          WHERE kind = 'cleared'
            AND created_at > $1::timestamptz
          LIMIT 1`,
        [lastRow.created_at],
      );
      if (clearedNewer.rowCount === 0) {
        const cleared = await fireAlert({
          kind: 'cleared',
          level: 'info',
          title: 'Resend exhausted backlog cleared',
          body: 'Semua failed delivery yang sebelumnya exhausted sudah resolved atau lewat TTL.',
          payload: { previousMaxId: lastMaxId },
        });
        return { fired: true, alert: cleared, reason: 'cleared' };
      }
    }
    return { fired: false, reason: 'no exhausted, no prior alert' };
  }

  // Case B: ada exhausted, tapi bukan baru (maxId tidak naik).
  if (snap.maxId <= lastMaxId) {
    return { fired: false, reason: 'no new exhausted since last alert' };
  }

  // Case C: ada exhausted baru, tapi masih dalam debounce window.
  if (sinceLastMs < debounceMs) {
    return {
      fired: false,
      reason: `debounced (${Math.round(sinceLastMs / 60000)}min < ${config.alerts.debounceMin}min)`,
    };
  }

  // Case D: fire.
  const level: 'warn' | 'critical' = snap.count >= 5 ? 'critical' : 'warn';
  const sampleLines = snap.samples
    .map((s) => `  • #${s.id} → ${s.target} (retry ${s.resend_count}): ${s.error ?? 'unknown'}`)
    .join('\n');
  const alert = await fireAlert({
    kind: 'exhausted_resend',
    level,
    title: `${snap.count} reply WA gagal kirim setelah retry max`,
    body:
      `Ada ${snap.count} baris di delivery_log dengan resend_count >= ${config.resend.maxAttempts} ` +
      `dan masih unresolved. Investigasi gateway WA atau target yang error.\n\n` +
      `Sample:\n${sampleLines}`,
    payload: {
      count: snap.count,
      maxId: snap.maxId,
      previousMaxId: lastMaxId,
      samples: snap.samples,
    },
  });
  return { fired: true, alert, reason: 'new exhausted' };
}

export async function listRecentAlerts(limit = 20): Promise<AlertRecord[]> {
  const r = await query<AlertRecord>(
    `SELECT id, kind, level, title, body, payload, channels_delivered,
            to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS created_at
       FROM alert_log
      ORDER BY created_at DESC
      LIMIT $1`,
    [Math.min(Math.max(limit, 1), 100)],
  );
  return r.rows;
}

/**
 * Cari `exhausted_resend` yang sudah tua (> ALERT_ESCALATE_AFTER_MIN)
 * tapi belum di-escalate dan belum ada `cleared` setelahnya. Untuk
 * setiap kandidat, fire critical-level alert dengan `escalation_for`
 * → parent.id, lalu update parent.escalated_at.
 *
 * Idempotent: parent.escalated_at filter mencegah double-escalation.
 */
export async function checkAndEscalate(): Promise<{
  escalated: number;
  alerts: AlertRecord[];
}> {
  const ageMin = config.alerts.escalateAfterMin;
  // Cari semua exhausted_resend yang sudah aged DAN belum di-escalate
  // DAN tidak ada cleared yang lebih baru.
  const candidates = await query<{
    id: number;
    title: string;
    body: string;
    payload: Record<string, unknown>;
    created_at: string;
    age_min: number;
  }>(
    `SELECT a.id, a.title, a.body, a.payload,
            to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS created_at,
            EXTRACT(EPOCH FROM (NOW() - a.created_at))::int / 60 AS age_min
       FROM alert_log a
      WHERE a.kind = 'exhausted_resend'
        AND a.escalated_at IS NULL
        AND a.created_at < NOW() - ($1 || ' minutes')::interval
        AND NOT EXISTS (
          SELECT 1 FROM alert_log c
           WHERE c.kind = 'cleared'
             AND c.created_at > a.created_at
        )
      ORDER BY a.created_at ASC`,
    [String(ageMin)],
  );

  if (candidates.rowCount === 0) {
    return { escalated: 0, alerts: [] };
  }

  const alerts: AlertRecord[] = [];
  for (const parent of candidates.rows) {
    const escAlert = await fireAlert({
      kind: 'escalation',
      level: 'critical',
      title: `🚨 ESCALATION: ${parent.title} (unresolved ${parent.age_min}m)`,
      body:
        `Alert #${parent.id} sudah unresolved selama ${parent.age_min} menit ` +
        `(threshold ${ageMin}m). Gateway WA kemungkinan masih bermasalah — ` +
        `cek dashboard Ops dan investigasi sekarang.\n\n` +
        `Original alert:\n${parent.body}`,
      payload: {
        ...parent.payload,
        ageMin: parent.age_min,
        thresholdMin: ageMin,
        parentAlertId: parent.id,
      },
    });
    // Tag escalation row + mark parent as escalated.
    await query(
      `UPDATE alert_log SET escalation_for = $1 WHERE id = $2`,
      [parent.id, escAlert.id],
    );
    await query(
      `UPDATE alert_log SET escalated_at = NOW() WHERE id = $1`,
      [parent.id],
    );
    alerts.push(escAlert);
  }
  return { escalated: alerts.length, alerts };
}
