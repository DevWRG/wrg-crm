import { sendReply } from './wa.js';
import { claimResendBatch, markResolved } from './repo/resend.js';
import { writeDelivery } from './repo/delivery.js';

export interface ResendOutcome {
  picked: number;
  delivered: number;
  failed: number;
}

/**
 * Pick + retry one batch of failed deliveries.
 *
 *   1. claim batch (atomic, race-safe)
 *   2. for each row: send via WA, write child delivery_log row
 *      (source='resend', parent_delivery_id=row.id)
 *   3. if child delivered, mark parent.resolved=true
 *
 * Aman dipanggil dari cron atau dari endpoint manual.
 */
export async function processResendBatch(): Promise<ResendOutcome> {
  const batch = await claimResendBatch();
  if (batch.length === 0) {
    return { picked: 0, delivered: 0, failed: 0 };
  }

  let delivered = 0;
  let failed = 0;

  await Promise.all(
    batch.map(async (row) => {
      const sent = await sendReply({
        to: row.to_kind,
        target: row.target,
        text: row.text_full,
      });
      await writeDelivery({
        auditId: row.audit_id,
        source: 'resend',
        messageIdIn: row.message_id_in,
        waNumber: row.wa_number,
        parentDeliveryId: row.id,
        sent,
      });
      if (sent.delivered) {
        await markResolved(row.id);
        delivered += 1;
      } else {
        failed += 1;
      }
    }),
  );

  return { picked: batch.length, delivered, failed };
}
