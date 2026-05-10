/**
 * Manual trigger untuk daily summary.
 *   npm run summary:run                 # untuk hari ini (WIB)
 *   npm run summary:run -- 2026-05-10   # untuk tanggal tertentu
 */

import { runDailySummary } from '../src/summary/index.js';
import { pool } from '../src/db.js';

const arg = process.argv[2];
if (arg && !/^\d{4}-\d{2}-\d{2}$/.test(arg)) {
  console.error('Tanggal harus format YYYY-MM-DD');
  process.exit(1);
}

(async () => {
  try {
    const r = await runDailySummary(arg, 'manual');
    console.log(`\n[summary tanggal=${r.tanggal} delivered=${r.sent.delivered}]`);
    if (r.sent.error) console.error('send error:', r.sent.error);
  } catch (err) {
    console.error('FATAL:', err);
    process.exit(1);
  } finally {
    await pool.end();
  }
})();
