-- Escalation linkage: ketika alert exhausted_resend tetap unresolved
-- selama X menit, detector akan fire alert kind='escalation' dengan
-- pointer ke alert parent (yang sudah aged).
--
-- escalation_for menunjuk ke baris parent. Setelah parent ter-escalate,
-- escalated_at parent diisi supaya detector tidak fire escalation lagi.

ALTER TABLE alert_log
  ADD COLUMN IF NOT EXISTS escalation_for INT REFERENCES alert_log(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS escalated_at   TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_alert_escalation_for
  ON alert_log(escalation_for);

-- Partial index untuk lookup cepat exhausted_resend yang belum di-escalate.
CREATE INDEX IF NOT EXISTS idx_alert_unescalated_warn
  ON alert_log(created_at)
  WHERE kind = 'exhausted_resend' AND escalated_at IS NULL;
