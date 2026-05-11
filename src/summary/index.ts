import { config } from '../config.js';
import { sendReply, type SentReply } from '../wa.js';
import { writeDelivery } from '../repo/delivery.js';
import { fetchSummary, type SummaryData } from './queries.js';
import { renderDailySummary } from './format.js';
import { todayWib } from '../util/dateid.js';
import type { DeliverySource } from '../repo/delivery.js';

export interface SummaryRunResult {
  tanggal: string;
  text: string;
  data: SummaryData;
  sent: SentReply;
}

/**
 * Build + send the daily summary for the given date (YYYY-MM-DD WIB).
 * Defaults to today in WIB. Sends to WA_HOD_GROUP_ID.
 *
 * `source` defaults to 'scheduler' (cron-driven). Pass 'manual' for
 * ad-hoc CLI / endpoint triggers.
 */
export async function runDailySummary(
  date?: string,
  source: DeliverySource = 'scheduler',
): Promise<SummaryRunResult> {
  const tanggal = date ?? todayWib();
  const data = await fetchSummary(tanggal);
  const text = await renderDailySummary(data);
  const sent = await sendReply({
    to: 'group',
    target: config.wa.hodGroupId,
    text,
  });
  await writeDelivery({
    auditId: null,
    source,
    messageIdIn: null,
    waNumber: null,
    sent,
  });
  return { tanggal, text, data, sent };
}
