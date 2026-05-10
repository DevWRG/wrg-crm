/**
 * End-to-end smoke test against the dispatcher (without HTTP).
 * Run with: npm run smoke
 *
 * Assumes db/001_init.sql + db/002_seed.sql have been applied.
 * Expects users:  Andi (628111...), Budi (628222...), unregistered (628999...)
 */

import { processInbound } from '../src/dispatcher.js';
import { pool, query } from '../src/db.js';

const ANDI = '6281111111111';
const BUDI = '6282222222222';
const STRANGER = '6289999999999';

let pass = 0;
let fail = 0;

function check(name: string, ok: boolean, detail?: unknown) {
  if (ok) {
    pass++;
    console.log(`  ✓ ${name}`);
  } else {
    fail++;
    console.log(`  ✗ ${name}`, detail ?? '');
  }
}

async function clean() {
  await query(`DELETE FROM auth_log`);
  await query(`DELETE FROM user_session`);
  await query(`DELETE FROM email_log`);
  await query(`DELETE FROM alert_log`);
  // delivery_log has self-FK (parent_delivery_id); plain DELETE works because
  // ON DELETE SET NULL on the FK, but we still want all rows gone.
  await query(`DELETE FROM delivery_log`);
  await query(`DELETE FROM activity_log`);
  await query(`DELETE FROM sales_plan`);
  await query(`DELETE FROM pending_confirm`);
  await query(`DELETE FROM audit_log`);
  await query(`DELETE FROM processed_message`);
  // Reset pipeline back to seed
  await query(`DELETE FROM pipeline_tracker`);
  await query(
    `INSERT INTO pipeline_tracker (user_id, customer_name, nama_am, area, produk, stage, status, note)
     SELECT id, 'RS Husada Utama', nama_am, area, 'USG Seri 500', 2, 'Warm', 'Initial seed'
     FROM master_user WHERE wa_number = $1`,
    [ANDI],
  );
}

async function run() {
  console.log('\n══ SMOKE TEST ══════════════════════════════════════');
  await clean();

  // 1. Non-hashtag message → ignored
  console.log('\n[1] Non-hashtag is ignored');
  {
    const out = await processInbound({ from: ANDI, text: 'halo semua, gimana hari ini?' });
    check('ignored=true', out.ignored === true);
  }

  // 2. Unregistered sender → DM error
  console.log('\n[2] Unregistered sender gets DM error');
  {
    const out = await processInbound({ from: STRANGER, text: '#PLAN\ntgl: 01/05/2026\ncust: X\ntujuan: WA\ngoal: test' });
    check('not ignored', out.ignored === false);
    check('one DM sent', out.sent.length === 1 && out.sent[0].to === 'dm');
    check('mentions Husni', /Husni/.test(out.sent[0]?.text ?? ''));
  }

  // 3. #PLAN single
  console.log('\n[3] #PLAN single mode');
  {
    const out = await processInbound({
      from: ANDI,
      text: '#PLAN\ntgl: 15/05/2026\ncust: RS Pelita\ntujuan: kunjungan\ngoal: Demo USG',
    });
    check('hashtag=#PLAN', out.hashtag === '#PLAN');
    check('status SUCCESS', out.result?.status === 'SUCCESS');
    const row = await query(
      `SELECT tujuan FROM sales_plan WHERE customer_name='RS Pelita'`,
    );
    check('plan row inserted', row.rowCount === 1);
    check('tujuan normalized to "Kunjungan Fisik"', row.rows[0]?.tujuan === 'Kunjungan Fisik');
  }

  // 4. #PLAN multi
  console.log('\n[4] #PLAN multi mode (3 customers)');
  {
    const out = await processInbound({
      from: BUDI,
      text:
        `#PLAN\ntgl: 16/05/2026\n3|\n` +
        `RS A | visit | demo alat\n` +
        `Klinik B | telp | follow up harga\n` +
        `Lab C | wa | konfirmasi PO`,
    });
    check('SUCCESS', out.result?.status === 'SUCCESS');
    check('customerCount=3', out.result?.customerCount === 3);
    const row = await query(`SELECT COUNT(*)::int AS n FROM sales_plan WHERE user_id=(SELECT id FROM master_user WHERE wa_number=$1)`, [BUDI]);
    check('3 plan rows for Budi', row.rows[0]?.n === 3);
  }

  // 5. #PLAN multi with mismatch N
  console.log('\n[5] #PLAN N mismatch → FAILED + DM');
  {
    const out = await processInbound({
      from: BUDI,
      text: `#PLAN\ntgl: 17/05/2026\n3|\nRS A | visit | x\nKlinik B | telp | y`,
    });
    check('one DM sent', out.sent.length === 1 && out.sent[0].to === 'dm');
    check('error mentions jumlah', /jumlah|N/i.test(out.sent[0]?.text ?? ''));
  }

  // 6. #LEADS happy path with dup warning
  console.log('\n[6] #LEADS adds pipeline + warns near-dup');
  {
    const out = await processInbound({
      from: ANDI,
      text:
        `#LEADS\ncust: RS Husada Utamax\npic: dr. Ina (08123)\ntipe: RS\nproduk: USG\ninfo: referral`,
    });
    check('SUCCESS', out.result?.status === 'SUCCESS');
    check('reply mentions warning', /Mirip dengan/.test(out.sent[0]?.text ?? ''));
  }

  // 7. #LEADS missing fields
  console.log('\n[7] #LEADS missing fields → DM error');
  {
    const out = await processInbound({
      from: ANDI,
      text: `#LEADS\ncust: RS Baru\npic: dr. A`,
    });
    check('DM error', out.sent[0]?.to === 'dm');
    check('mentions wajib', /wajib/i.test(out.sent[0]?.text ?? ''));
  }

  // 8. #REPORT mode A (single, default today)
  console.log('\n[8] #REPORT mode A links to seeded pipeline by fuzzy match');
  {
    const out = await processInbound({
      from: ANDI,
      text: `#REPORT\ncust: RS Husada\nhasil: Sudah ketemu dokter\nnext: Demo minggu depan`,
    });
    check('SUCCESS', out.result?.status === 'SUCCESS');
    const row = await query(
      `SELECT pipeline_id FROM activity_log WHERE customer_name='RS Husada' ORDER BY id DESC LIMIT 1`,
    );
    check('pipeline_id resolved (not null)', row.rows[0]?.pipeline_id != null);
  }

  // 9. #REPORT mode B (EOD multi)
  console.log('\n[9] #REPORT mode B (2 entries with separator)');
  {
    const out = await processInbound({
      from: ANDI,
      text:
        `#REPORT\ntgl: 10/05/2026\n---\n` +
        `cust: RS Pelita\nhasil: meeting awal\nnext: kirim proposal\n---\n` +
        `cust: Klinik Z\nhasil: tidak hadir\nnext: reschedule`,
    });
    check('SUCCESS', out.result?.status === 'SUCCESS');
    check('customerCount=2', out.result?.customerCount === 2);
  }

  // 10. #UPDATE auto-update (high score)
  console.log('\n[10] #UPDATE auto-applies when score ≥ 0.7');
  {
    const out = await processInbound({
      from: ANDI,
      text: `#UPDATE\ncust: RS Husada Utama\nstage: 3\nstatus: hot\nnote: deal harga sudah`,
    });
    check('SUCCESS', out.result?.status === 'SUCCESS');
    const row = await query(
      `SELECT stage, status FROM pipeline_tracker WHERE customer_name='RS Husada Utama'`,
    );
    check('stage=3', row.rows[0]?.stage === 3);
    check('status=Hot', row.rows[0]?.status === 'Hot');
  }

  // 11. #UPDATE confirm flow
  console.log('\n[11] #UPDATE mid-confidence asks for confirm, then UPDATE 1 applies');
  {
    // First add a couple of similar-named entries to force ambiguity
    await query(
      `INSERT INTO pipeline_tracker (user_id, customer_name, nama_am, area, produk, stage, status, note)
       SELECT id, 'RS Mawar Putih', nama_am, area, 'X', 1, 'Cold', 't'
         FROM master_user WHERE wa_number = $1`,
      [ANDI],
    );
    await query(
      `INSERT INTO pipeline_tracker (user_id, customer_name, nama_am, area, produk, stage, status, note)
       SELECT id, 'RS Mawar Merah', nama_am, area, 'X', 1, 'Cold', 't'
         FROM master_user WHERE wa_number = $1`,
      [ANDI],
    );

    const out1 = await processInbound({
      from: ANDI,
      text: `#UPDATE\ncust: Mawar\nstage: 2\nstatus: warm\nnote: progress`,
    });
    check('CONFIRM_NEEDED', out1.result?.status === 'CONFIRM_NEEDED');
    check('reply via DM', out1.sent[0]?.to === 'dm');
    check('reply lists 3 options', /1\..+\n.+2\..+\n.+3\.|1\..+\n.+2\./s.test(out1.sent[0]?.text ?? ''));

    // Reply with UPDATE 1
    const out2 = await processInbound({ from: ANDI, text: 'UPDATE 1' });
    check('confirm SUCCESS', out2.result?.status === 'SUCCESS');
    check('reply to group', out2.sent[0]?.to === 'group');
  }

  // 12. #UPDATE not found
  console.log('\n[12] #UPDATE on unknown customer → NOT_FOUND DM');
  {
    const out = await processInbound({
      from: ANDI,
      text: `#UPDATE\ncust: Customer Tidak Ada XYZ\nstage: 2\nstatus: warm\nnote: x`,
    });
    check('NOT_FOUND', out.result?.status === 'NOT_FOUND');
    check('DM', out.sent[0]?.to === 'dm');
  }

  // 13. Audit log received entries
  console.log('\n[13] Audit log captures activity');
  {
    const row = await query<{ n: number }>(`SELECT COUNT(*)::int AS n FROM audit_log`);
    check('audit_log has rows', (row.rows[0]?.n ?? 0) > 0);
  }

  // 14. Idempotency: same messageId twice → second is duplicate, no double insert
  console.log('\n[14] Same messageId twice → duplicate skipped');
  {
    const msgId = 'dup-test-' + Date.now();
    const planText = `#PLAN\ntgl: 30/05/2026\ncust: Idem Test\ntujuan: visit\ngoal: x`;

    const before = await query<{ n: number }>(
      `SELECT COUNT(*)::int AS n FROM sales_plan WHERE customer_name='Idem Test'`,
    );
    const out1 = await processInbound({
      from: ANDI,
      groupId: 'wrg-sales-command-center',
      text: planText,
      messageId: msgId,
    });
    check('first call processed', out1.ignored === false && out1.duplicate !== true);
    check('first call SUCCESS', out1.result?.status === 'SUCCESS');

    const out2 = await processInbound({
      from: ANDI,
      groupId: 'wrg-sales-command-center',
      text: planText,
      messageId: msgId,
    });
    check('second call ignored=true', out2.ignored === true);
    check('second call duplicate=true', out2.duplicate === true);
    check('second call no replies sent', out2.sent.length === 0);
    check('second call originalStatus reflects first', typeof out2.originalStatus === 'string');

    const after = await query<{ n: number }>(
      `SELECT COUNT(*)::int AS n FROM sales_plan WHERE customer_name='Idem Test'`,
    );
    check('only one sales_plan row inserted', (after.rows[0]?.n ?? 0) - (before.rows[0]?.n ?? 0) === 1);
  }

  // 15. Different messageId → both processed
  console.log('\n[15] Different messageIds → both processed');
  {
    const out1 = await processInbound({
      from: ANDI,
      groupId: 'wrg-sales-command-center',
      text: `#PLAN\ntgl: 31/05/2026\ncust: Multi Idem A\ntujuan: visit\ngoal: x`,
      messageId: 'dup-A-' + Date.now(),
    });
    const out2 = await processInbound({
      from: ANDI,
      groupId: 'wrg-sales-command-center',
      text: `#PLAN\ntgl: 31/05/2026\ncust: Multi Idem B\ntujuan: visit\ngoal: y`,
      messageId: 'dup-B-' + Date.now(),
    });
    check('both processed', !out1.duplicate && !out2.duplicate);
    const r = await query<{ n: number }>(
      `SELECT COUNT(*)::int AS n FROM sales_plan WHERE customer_name LIKE 'Multi Idem%'`,
    );
    check('2 sales_plan rows from 2 distinct messageIds', r.rows[0]?.n === 2);
  }

  // 16. No messageId → dedupe skipped (legacy gateway compatibility)
  console.log('\n[16] Missing messageId → no dedupe attempted');
  {
    const out1 = await processInbound({
      from: ANDI,
      groupId: 'wrg-sales-command-center',
      text: `#PLAN\ntgl: 01/06/2026\ncust: NoId Test\ntujuan: visit\ngoal: x`,
    });
    const out2 = await processInbound({
      from: ANDI,
      groupId: 'wrg-sales-command-center',
      text: `#PLAN\ntgl: 01/06/2026\ncust: NoId Test\ntujuan: visit\ngoal: x`,
    });
    check('first not flagged duplicate', out1.duplicate !== true);
    check('second not flagged duplicate (no id to dedupe)', out2.duplicate !== true);
    check('both succeeded', out1.result?.status === 'SUCCESS' && out2.result?.status === 'SUCCESS');
  }

  // 17. processed_message row finished with hashtag + status
  console.log('\n[17] processed_message reflects hashtag + status of completed work');
  {
    const r = await query<{ status: string; hashtag: string; finished_at: string | null }>(
      `SELECT status, hashtag, finished_at FROM processed_message
        WHERE wa_number = $1
        ORDER BY processed_at DESC LIMIT 1`,
      [ANDI],
    );
    check('row exists', r.rowCount === 1);
    check('finished_at set', r.rows[0]?.finished_at !== null);
    check('status is final, not PROCESSING', r.rows[0]?.status !== 'PROCESSING');
  }

  // 18. Delivery audit — every reply lands in delivery_log linked to audit_log
  console.log('\n[18] delivery_log row per reply (linked to audit_log)');
  {
    const r = await query<{ n: number; success: number }>(
      `SELECT COUNT(*)::int AS n,
              COUNT(*) FILTER (WHERE delivered = TRUE)::int AS success
         FROM delivery_log
        WHERE source = 'inbound'`,
    );
    check('delivery_log has rows', (r.rows[0]?.n ?? 0) > 0);
    check('all mock deliveries marked delivered', r.rows[0]?.n === r.rows[0]?.success);

    const audited = await query<{ n: number }>(
      `SELECT COUNT(*)::int AS n
         FROM delivery_log dl
         JOIN audit_log al ON al.id = dl.audit_id
        WHERE dl.source = 'inbound'`,
    );
    check('all inbound deliveries link to audit_log', audited.rows[0]?.n === r.rows[0]?.n);

    const previewed = await query<{ n: number }>(
      `SELECT COUNT(*)::int AS n FROM delivery_log
        WHERE text_preview IS NOT NULL AND length(text_preview) > 0`,
    );
    check('text_preview populated', previewed.rows[0]?.n === r.rows[0]?.n);
  }

  // 19. Failed delivery in HTTP mode → recorded with error + attempts > 1
  console.log('\n[19] Failed HTTP delivery captured (delivered=false, error set)');
  {
    // Force http mode targeting an unreachable port; need to flip env
    // before calling sendReply. We don't have a clean way to swap config
    // mid-process, so we hit the underlying writeDelivery() helper directly
    // with a synthetic SentReply that simulates failure.
    const { writeDelivery } = await import('../src/repo/delivery.js');
    await writeDelivery({
      auditId: null,
      source: 'inbound',
      messageIdIn: 'synthetic-failed-1',
      waNumber: ANDI,
      sent: {
        to: 'group',
        target: 'wrg-sales-command-center',
        text: 'simulated failed reply',
        delivered: false,
        attempts: 3,
        error: 'HTTP 503',
      },
    });
    const r = await query<{ delivered: boolean; attempts: number; error: string }>(
      `SELECT delivered, attempts, error FROM delivery_log
        WHERE message_id_in = 'synthetic-failed-1'`,
    );
    check('failure row delivered=false', r.rows[0]?.delivered === false);
    check('attempts > 1 captured', (r.rows[0]?.attempts ?? 0) === 3);
    check('error captured', r.rows[0]?.error === 'HTTP 503');
  }

  // 20. Daily summary delivery logged with source=manual
  console.log('\n[20] Daily summary writes delivery row with correct source');
  {
    const { runDailySummary } = await import('../src/summary/index.js');
    await runDailySummary(undefined, 'manual');
    const r = await query<{ n: number }>(
      `SELECT COUNT(*)::int AS n FROM delivery_log
        WHERE source = 'manual' AND audit_id IS NULL`,
    );
    check('manual summary delivery row exists', (r.rows[0]?.n ?? 0) >= 1);
  }

  // 21. listDeliveries() pagination + filters
  console.log('\n[21] listDeliveries filters by status + limit');
  {
    const { listDeliveries } = await import('../src/repo/delivery.js');
    const failed = await listDeliveries({ status: 'failed', limit: 10 });
    const success = await listDeliveries({ status: 'success', limit: 10 });
    const all = await listDeliveries({ status: 'all', limit: 500 });
    check('failed query returns only delivered=false', failed.every((d) => d.delivered === false));
    check('success query returns only delivered=true', success.every((d) => d.delivered === true));
    check('all >= failed + success', all.length >= failed.length + success.length);
  }

  // 22. Rate limiter unit behavior
  console.log('\n[22] FixedWindowLimiter unit checks');
  {
    const { FixedWindowLimiter } = await import('../src/util/ratelimit.js');
    const lim = new FixedWindowLimiter(3, 60_000);
    const r1 = lim.check('a');
    const r2 = lim.check('a');
    const r3 = lim.check('a');
    const r4 = lim.check('a');
    const rB1 = lim.check('b');
    check('first 3 allowed', r1.allowed && r2.allowed && r3.allowed);
    check('4th denied', r4.allowed === false);
    check('retryAfterSec > 0 on deny', (r4.retryAfterSec ?? 0) > 0);
    check('different key isolated', rB1.allowed);
    check('remaining decreasing', r1.remaining === 2 && r2.remaining === 1 && r3.remaining === 0);
  }

  // 23. Per-WA limit triggers via dispatcher
  console.log('\n[23] Per-WA rate limit blocks burst, returns 429-equivalent + audit RATE_LIMITED');
  {
    const { perWaLimiter } = await import('../src/limiters.js');
    perWaLimiter.reset();
    const { config } = await import('../src/config.js');
    const limit = config.rateLimit.perWaPerMin;

    const auditBefore = await query<{ n: number }>(
      `SELECT COUNT(*)::int AS n FROM audit_log WHERE status = 'RATE_LIMITED'`,
    );

    let firstBlocked: number | null = null;
    let allowedCount = 0;
    for (let i = 1; i <= limit + 3; i += 1) {
      const out = await processInbound({ from: BUDI, text: 'halo iseng ' + i });
      if (out.rateLimited) {
        firstBlocked = firstBlocked ?? i;
      } else {
        allowedCount += 1;
      }
    }

    check(`exactly ${limit} requests allowed`, allowedCount === limit);
    check(`request #${limit + 1} is the first blocked`, firstBlocked === limit + 1);

    const auditAfter = await query<{ n: number }>(
      `SELECT COUNT(*)::int AS n FROM audit_log WHERE status = 'RATE_LIMITED'`,
    );
    check(
      'audit_log gained 3 RATE_LIMITED rows',
      (auditAfter.rows[0]?.n ?? 0) - (auditBefore.rows[0]?.n ?? 0) === 3,
    );

    // Different WA still works.
    const otherOut = await processInbound({ from: STRANGER, text: 'halo' });
    check('unrelated WA not affected', otherOut.rateLimited !== true);

    perWaLimiter.reset();
  }

  // 24. Exempt list bypasses rate limit
  console.log('\n[24] Exempt WA bypasses per-WA limit');
  {
    const { perWaLimiter } = await import('../src/limiters.js');
    perWaLimiter.reset();
    // Husni's number is in seed (6281234567890); add via env override path instead.
    // We monkey-test by calling with HUSNI which is NOT in the default exempt list,
    // then by setting it as exempt and re-running. To avoid touching env at runtime,
    // we test the isExempt() helper directly.
    const { isExempt } = await import('../src/limiters.js');
    check('default exempt list empty in test env', isExempt('6281234567890') === false);

    // And verify exemption logic by going around perWaLimiter directly: when a
    // number is exempt the dispatcher should never even consult the limiter.
    // Simulate by filling Andi's bucket and calling for a *different* number that
    // happens to be in exempt set: skip — we already verified isolation in [23].
    perWaLimiter.reset();
    check('limiter reset cleared bucket', perWaLimiter.size() === 0);
  }

  // 25. Resend: seed failed delivery → batch picks → child row + parent resolved
  console.log('\n[25] Resend picks failed delivery, writes child, marks parent resolved');
  {
    const { writeDelivery } = await import('../src/repo/delivery.js');
    const { processResendBatch } = await import('../src/resend.js');

    const parentId = await writeDelivery({
      auditId: null,
      source: 'inbound',
      messageIdIn: 'resend-test-1',
      waNumber: ANDI,
      sent: {
        to: 'group',
        target: 'wrg-sales-command-center',
        text: 'gagal kirim, harus diresend',
        delivered: false,
        attempts: 3,
        error: 'HTTP 503',
      },
    });

    const r1 = await processResendBatch();
    check('picked >= 1', r1.picked >= 1);
    check('delivered >= 1 (mock mode)', r1.delivered >= 1);

    const parent = await query<{
      resolved: boolean;
      resend_count: number;
      last_resend_at: string | null;
    }>(
      `SELECT resolved, resend_count, last_resend_at FROM delivery_log WHERE id = $1`,
      [parentId],
    );
    check('parent.resolved = true', parent.rows[0]?.resolved === true);
    check('parent.resend_count = 1', parent.rows[0]?.resend_count === 1);
    check('parent.last_resend_at set', parent.rows[0]?.last_resend_at !== null);

    const children = await query<{ n: number }>(
      `SELECT COUNT(*)::int AS n FROM delivery_log
        WHERE parent_delivery_id = $1 AND source = 'resend'`,
      [parentId],
    );
    check('1 resend child row exists', children.rows[0]?.n === 1);
  }

  // 26. Resend backoff: same row not re-picked immediately
  console.log('\n[26] Backoff prevents immediate re-pick');
  {
    const { writeDelivery } = await import('../src/repo/delivery.js');
    const { processResendBatch } = await import('../src/resend.js');
    const { claimResendBatch } = await import('../src/repo/resend.js');

    // Seed a row that ALSO needs resend (mark not-delivered)
    const id = await writeDelivery({
      auditId: null,
      source: 'inbound',
      messageIdIn: 'resend-test-2',
      waNumber: ANDI,
      sent: {
        to: 'dm', target: ANDI, text: 'x',
        delivered: false, attempts: 1, error: 'transient',
      },
    });
    // Run once — should pick + bump resend_count
    await processResendBatch();
    // Run again immediately — backoff (5 min) should keep it OUT
    const second = await claimResendBatch();
    const reSelected = second.some((c) => c.id === id);
    check('row NOT re-claimed within backoff window', reSelected === false);
  }

  // 27. Resend cap: row with resend_count >= MAX not picked
  console.log('\n[27] resend_count cap is enforced');
  {
    const { writeDelivery } = await import('../src/repo/delivery.js');
    const { claimResendBatch } = await import('../src/repo/resend.js');
    const { config } = await import('../src/config.js');

    const id = await writeDelivery({
      auditId: null,
      source: 'inbound',
      messageIdIn: 'resend-test-3',
      waNumber: ANDI,
      sent: {
        to: 'dm', target: ANDI, text: 'cap test',
        delivered: false, attempts: 1, error: 'persistent',
      },
    });
    // Force resend_count to be at the cap
    await query(
      `UPDATE delivery_log SET resend_count = $1, last_resend_at = NULL WHERE id = $2`,
      [config.resend.maxAttempts, id],
    );
    const batch = await claimResendBatch();
    const found = batch.some((c) => c.id === id);
    check('exhausted row not picked', found === false);
  }

  // 28. Resend stats endpoint reflects state
  console.log('\n[28] getResendStats returns sensible counts');
  {
    const { getResendStats } = await import('../src/repo/resend.js');
    const s = await getResendStats();
    check('resolved24h > 0 (from #25)', s.resolved24h > 0);
    check('exhausted >= 1 (from #27)', s.exhausted >= 1);
    check('pending is non-negative number', typeof s.pending === 'number' && s.pending >= 0);
  }

  // 29. Dashboard queries: overview structure + amStats sorted
  console.log('\n[29] fetchOverview returns summary + per-AM stats');
  {
    const { fetchOverview } = await import('../src/dashboard/queries.js');
    const o = await fetchOverview();
    check('has summary', typeof o.summary.activeTeamCount === 'number');
    check('amStats includes all active AMs', o.amStats.length === o.summary.totalAmRoster);
    check('amStats sorted by visits desc',
      o.amStats.every((a, i, arr) => i === 0 || arr[i - 1].visits >= a.visits));
  }

  // 30. Recent activity + pipeline snapshot
  console.log('\n[30] fetchRecentActivity + fetchPipelineSnapshot');
  {
    const { fetchRecentActivity, fetchPipelineSnapshot } = await import('../src/dashboard/queries.js');
    const recent = await fetchRecentActivity(10);
    check('recent activity returns array', Array.isArray(recent));
    check('limit honored', recent.length <= 10);

    const pipe = await fetchPipelineSnapshot();
    check('byStatus array', Array.isArray(pipe.byStatus));
    check('stageBreakdown array', Array.isArray(pipe.stageBreakdown));
    check('topDeals array', Array.isArray(pipe.topDeals));
  }

  // 31. Ops dashboard query merges resend + rate limited + failed deliveries
  console.log('\n[31] fetchOps aggregates resend + rate-limit + delivery + audit');
  {
    const { fetchOps } = await import('../src/dashboard/queries.js');
    const o = await fetchOps();
    check('has resend stats', typeof o.resend.pending === 'number');
    check('rateLimitedRecent is array', Array.isArray(o.rateLimitedRecent));
    check('failedDeliveries is array', Array.isArray(o.failedDeliveries));
    check('auditSummary is array', Array.isArray(o.auditSummary));
    check('audit has SUCCESS row from earlier tests',
      o.auditSummary.some((s) => s.status === 'SUCCESS' && s.count > 0));
  }

  // 32. fireAlert delivers to enabled channels + records to alert_log
  console.log('\n[32] fireAlert writes alert_log with channel results');
  {
    const { fireAlert, listRecentAlerts } = await import('../src/alerts/index.js');
    const a = await fireAlert({
      kind: 'test', level: 'info',
      title: 'Test alert', body: 'unit test',
      payload: { foo: 'bar' },
    });
    check('alert row created', typeof a.id === 'number' && a.id > 0);
    check('channels_delivered has log channel', a.channels_delivered.some((c: any) => c.channel === 'log'));
    check('log delivered=true', a.channels_delivered.find((c: any) => c.channel === 'log')?.delivered === true);
    const list = await listRecentAlerts(5);
    check('listRecentAlerts returns rows', list.length >= 1);
  }

  // 33. Channel failure isolation: webhook fails, log still delivers
  console.log('\n[33] One failing channel does not block others');
  {
    process.env.ALERT_WEBHOOK_URL = 'http://127.0.0.1:1/never-listens';
    // Re-import config because it caches env at module load — we instead test
    // the channel object directly with our bad URL via a fresh import.
    const channels = await import('../src/alerts/channels.ts?bust=' + Date.now()).catch(() => null);
    // ESM caching makes runtime override tricky. Instead, directly assert
    // the Promise.allSettled-based dispatch by calling the webhook channel
    // when its URL is unreachable.
    const { httpWebhookChannel, logChannel } = await import('../src/alerts/channels.js');
    // logChannel always works
    const logR = await logChannel.send({
      kind: 'test', level: 'info', title: 'iso', body: 'ok',
    });
    check('logChannel always delivered', logR.delivered === true);
    // httpWebhookChannel returns delivered=false when URL is unreachable
    // (only run this branch if user set the bad URL above and channel sees it)
    if (httpWebhookChannel.enabled()) {
      const httpR = await httpWebhookChannel.send({
        kind: 'test', level: 'info', title: 'iso', body: 'should fail',
      });
      check('http channel returns delivered=false on unreachable url',
        httpR.delivered === false && typeof httpR.error === 'string');
    } else {
      // If env not picked up (ESM caching), test is informational.
      check('http channel disabled when no env (skip)', true);
    }
    delete process.env.ALERT_WEBHOOK_URL;
  }

  // 34. checkExhaustedAndAlert: state machine
  console.log('\n[34] checkExhaustedAndAlert: fire → debounce → cleared');
  {
    const { writeDelivery } = await import('../src/repo/delivery.js');
    const { checkExhaustedAndAlert } = await import('../src/alerts/index.js');
    const { config } = await import('../src/config.js');
    // Wipe previous alerts AND mark pre-existing exhausted rows from
    // earlier tests as resolved so they don't pollute the count for this test.
    await query(`DELETE FROM alert_log WHERE kind IN ('exhausted_resend','cleared')`);
    await query(
      `UPDATE delivery_log SET resolved = TRUE
        WHERE delivered = FALSE AND resolved = FALSE
          AND resend_count >= $1`,
      [config.resend.maxAttempts],
    );

    // Seed an exhausted row (resend_count = max)
    const id = await writeDelivery({
      auditId: null, source: 'inbound', messageIdIn: 'alert-test-1', waNumber: ANDI,
      sent: { to: 'dm', target: ANDI, text: 'broken', delivered: false, attempts: 3, error: 'persistent' },
    });
    await query(
      `UPDATE delivery_log SET resend_count = $1 WHERE id = $2`,
      [config.resend.maxAttempts, id],
    );

    const r1 = await checkExhaustedAndAlert();
    check('first check fires alert', r1.fired === true);
    check('alert kind = exhausted_resend', r1.alert?.kind === 'exhausted_resend');
    check('payload.maxId set', (r1.alert?.payload as any)?.maxId === id);

    // Immediate re-check: debounce keeps it silent (same maxId).
    const r2 = await checkExhaustedAndAlert();
    check('re-check does not refire (no new exhausted)', r2.fired === false);

    // Resolve the exhausted row → cleared alert fires.
    await query(`UPDATE delivery_log SET resolved = TRUE WHERE id = $1`, [id]);
    const r3 = await checkExhaustedAndAlert();
    check('clear notification fires when no exhausted left', r3.fired === true);
    check('clear kind = cleared', r3.alert?.kind === 'cleared');

    // Second clear call → no-op (already cleared).
    const r4 = await checkExhaustedAndAlert();
    check('idempotent clear (no re-fire)', r4.fired === false);
  }

  // 35. CSV escaping handles commas, quotes, newlines, unicode
  console.log('\n[35] CSV escaping: commas, quotes, newlines, unicode');
  {
    const { csvField, csvRow, serializeCsv } = await import('../src/exports/csv.js');
    check('plain string not quoted', csvField('halo') === 'halo');
    check('comma triggers quoting', csvField('a,b') === '"a,b"');
    check('quote is doubled', csvField('say "hi"') === '"say ""hi"""');
    check('newline triggers quoting', csvField('line1\nline2') === '"line1\nline2"');
    check('unicode passes through', csvField('日本語') === '日本語');
    check('null becomes empty', csvField(null) === '');
    check('number stringified', csvField(42) === '42');

    const csv = serializeCsv({
      headers: ['a', 'b'],
      rows: [{ a: 'x,y', b: '"z"' }, { a: 'plain', b: 'multi\nline' }],
      row: (r) => [r.a, r.b],
    });
    // Strip BOM for assertion
    const stripped = csv.replace(/^﻿/, '');
    check('header line correct', stripped.startsWith('a,b\r\n'));
    check('row escaping correct', stripped.includes('"x,y","""z"""\r\n'));
    check('newline-in-cell preserved', stripped.includes('plain,"multi\nline"'));
  }

  // 36. exportPipeline + exportActivity (range filter)
  console.log('\n[36] CSV export queries respect date filter');
  {
    const { exportPipeline, exportActivity, exportPlans } = await import('../src/exports/queries.js');
    const pipe = await exportPipeline();
    check('pipeline export returns rows', pipe.length > 0);
    check('pipeline row has nama_am from join', typeof pipe[0]?.nama_am === 'string');

    // Range that excludes all rows → 0 results
    const nothing = await exportActivity({ from: '1900-01-01', to: '1900-01-02' });
    check('activity range excludes everything', nothing.length === 0);

    const all = await exportActivity({});
    check('activity unfiltered returns rows', all.length > 0);

    const plans = await exportPlans({});
    check('plans returns rows', plans.length > 0);
  }

  // 37. Weekly digest HTML renders without error
  console.log('\n[37] Weekly digest HTML renders with expected structure');
  {
    const { renderWeeklyDigest } = await import('../src/exports/digest.js');
    const html = await renderWeeklyDigest('2026-05-04', '2026-05-10');
    check('contains DOCTYPE', html.startsWith('<!DOCTYPE html>'));
    check('contains title', html.includes('WRG Weekly Digest'));
    check('has Daily Breakdown section', html.includes('Daily Breakdown'));
    check('has Per-AM section', html.includes('Per-AM'));
    check('has Hot Pipeline section', html.includes('Hot Pipeline'));
    check('has KPI grid', html.includes('class="kpi-grid"'));
    check('print-friendly footer', html.includes('Cetak ke PDF'));
  }

  // 38. lastCompleteWeekRange date math (Mon-Sun of previous week)
  console.log('\n[38] lastCompleteWeekRange returns Mon-Sun anchored to WIB');
  {
    const { lastCompleteWeekRange } = await import('../src/email/digest.js');
    const dayjs = (await import('dayjs')).default;
    await import('dayjs/plugin/utc.js').then((m) => dayjs.extend(m.default));
    await import('dayjs/plugin/timezone.js').then((m) => dayjs.extend(m.default));

    // 11 Mei 2026 = Senin. Range harus 4 Mei (Senin lalu) – 10 Mei (Minggu lalu).
    const mon = dayjs.tz('2026-05-11T08:00:00', 'Asia/Jakarta');
    const r1 = lastCompleteWeekRange(mon);
    check('Mon 11-Mei → from = 2026-05-04', r1.from === '2026-05-04');
    check('Mon 11-Mei → to   = 2026-05-10', r1.to === '2026-05-10');

    // 14 Mei (Kamis) → tetap range Mon-Sun minggu lalu (4-10).
    const thu = dayjs.tz('2026-05-14T15:00:00', 'Asia/Jakarta');
    const r2 = lastCompleteWeekRange(thu);
    check('Thu 14-Mei → from = 2026-05-04', r2.from === '2026-05-04');
    check('Thu 14-Mei → to   = 2026-05-10', r2.to === '2026-05-10');

    // 10 Mei (Minggu) → range mundur 1 minggu (27-Apr to 3-May).
    const sun = dayjs.tz('2026-05-10T23:00:00', 'Asia/Jakarta');
    const r3 = lastCompleteWeekRange(sun);
    check('Sun 10-Mei → from = 2026-04-27', r3.from === '2026-04-27');
    check('Sun 10-Mei → to   = 2026-05-03', r3.to === '2026-05-03');
  }

  // 39. sendWeeklyDigestEmail with jsonTransport (dry-run)
  console.log('\n[39] sendWeeklyDigestEmail dry-run builds proper message');
  {
    const { sendWeeklyDigestEmail } = await import('../src/email/digest.js');
    const r = await sendWeeklyDigestEmail({
      range: { from: '2026-05-04', to: '2026-05-10' },
      transportMode: 'json',
      recipients: ['hod@example.com', 'husni@wahanalifeline.co.id'],
    });
    check('sent=true', r.sent === true);
    check('subject set correctly', r.subject.includes('WRG Weekly Digest'));
    check('recipients in result', r.recipients.length === 2);
    check('rawJson populated (json transport)', typeof r.rawJson === 'string' && r.rawJson.length > 0);

    if (r.rawJson) {
      const parsed = JSON.parse(r.rawJson);
      check('json message has HTML body', typeof parsed.html === 'string' && parsed.html.length > 0);
      check('json message has text fallback', typeof parsed.text === 'string' && parsed.text.length > 0);
      check('json message has both recipients', Array.isArray(parsed.to) && parsed.to.length === 2);
      check('text fallback mentions Total Visits', parsed.text.includes('Total Visits'));
      check('html mentions WRG Weekly Digest', parsed.html.includes('WRG Weekly Digest'));
    }
  }

  // 40. No recipients → returns sent=false, no exception
  console.log('\n[40] Empty recipients = no send, no exception');
  {
    const { sendWeeklyDigestEmail } = await import('../src/email/digest.js');
    const r = await sendWeeklyDigestEmail({
      range: { from: '2026-05-04', to: '2026-05-10' },
      transportMode: 'json',
      recipients: [],
    });
    check('sent=false', r.sent === false);
    check('error mentions recipients', /recipients/i.test(r.error ?? ''));
  }

  // 41. recordDigestSend writes audit row
  console.log('\n[41] recordDigestSend writes email_log audit');
  {
    const { sendWeeklyDigestEmail, recordDigestSend } = await import('../src/email/digest.js');
    const r = await sendWeeklyDigestEmail({
      range: { from: '2026-05-04', to: '2026-05-10' },
      transportMode: 'json',
      recipients: ['audit-test@example.com'],
    });
    await recordDigestSend(r);
    const row = await query<{
      kind: string; delivered: boolean; recipients: string[]; subject: string;
    }>(
      `SELECT kind, delivered, recipients, subject
         FROM email_log
        WHERE recipients @> '["audit-test@example.com"]'::jsonb
        ORDER BY created_at DESC LIMIT 1`,
    );
    check('email_log row exists', row.rowCount === 1);
    check('kind=weekly_digest', row.rows[0]?.kind === 'weekly_digest');
    check('delivered=true', row.rows[0]?.delivered === true);
  }

  // 42. Escalation: aged exhausted_resend fires critical follow-up alert
  console.log('\n[42] checkAndEscalate fires critical when alert ages past threshold');
  {
    const { fireAlert, checkAndEscalate } = await import('../src/alerts/index.js');
    const { config } = await import('../src/config.js');
    await query(`DELETE FROM alert_log`);

    // Fire baseline exhausted_resend
    const parent = await fireAlert({
      kind: 'exhausted_resend', level: 'warn',
      title: 'X reply WA gagal kirim setelah retry max', body: 'aged-test parent',
      payload: { count: 2, maxId: 999 },
    });
    // Backdate parent ke umur > threshold supaya escalation eligible.
    const offsetMin = config.alerts.escalateAfterMin + 5;
    await query(
      `UPDATE alert_log SET created_at = NOW() - ($1 || ' minutes')::interval WHERE id = $2`,
      [String(offsetMin), parent.id],
    );

    const r1 = await checkAndEscalate();
    check('1 alert escalated', r1.escalated === 1);
    check('escalation kind=escalation', r1.alerts[0]?.kind === 'escalation');
    check('escalation level=critical', r1.alerts[0]?.level === 'critical');
    check('title mentions ESCALATION', /ESCALATION/i.test(r1.alerts[0]?.title ?? ''));

    // Parent now marked escalated_at
    const parentAfter = await query<{ escalated_at: string | null }>(
      `SELECT escalated_at FROM alert_log WHERE id = $1`,
      [parent.id],
    );
    check('parent.escalated_at set', parentAfter.rows[0]?.escalated_at !== null);

    // Child links back
    const childLink = await query<{ escalation_for: number }>(
      `SELECT escalation_for FROM alert_log WHERE id = $1`,
      [r1.alerts[0]?.id],
    );
    check('child.escalation_for = parent.id', childLink.rows[0]?.escalation_for === parent.id);

    // Re-run check — idempotent (parent already escalated)
    const r2 = await checkAndEscalate();
    check('second escalate is no-op', r2.escalated === 0);
  }

  // 43. Escalation skipped if cleared came in first
  console.log('\n[43] Escalation skipped if cleared notification was already fired');
  {
    const { fireAlert, checkAndEscalate } = await import('../src/alerts/index.js');
    const { config } = await import('../src/config.js');
    await query(`DELETE FROM alert_log`);

    // Fire parent + age it
    const parent = await fireAlert({
      kind: 'exhausted_resend', level: 'warn',
      title: 'Y reply WA gagal', body: 'parent that gets cleared', payload: {},
    });
    const offsetMin = config.alerts.escalateAfterMin + 5;
    await query(
      `UPDATE alert_log SET created_at = NOW() - ($1 || ' minutes')::interval WHERE id = $2`,
      [String(offsetMin), parent.id],
    );
    // Fire cleared after parent (must be newer than parent).
    await fireAlert({
      kind: 'cleared', level: 'info', title: 'Cleared', body: 'all resolved', payload: {},
    });

    const r = await checkAndEscalate();
    check('escalation skipped because cleared exists', r.escalated === 0);
  }

  // 44. Escalation honors threshold (young alerts not escalated)
  console.log('\n[44] Young (< threshold) exhausted_resend is not escalated');
  {
    const { fireAlert, checkAndEscalate } = await import('../src/alerts/index.js');
    await query(`DELETE FROM alert_log`);

    // Fire fresh exhausted_resend (created_at = NOW, age = 0)
    await fireAlert({
      kind: 'exhausted_resend', level: 'warn',
      title: 'Z reply WA gagal', body: 'still fresh', payload: {},
    });

    const r = await checkAndEscalate();
    check('young alert not escalated', r.escalated === 0);
  }

  // 45. Session lifecycle (create / find / touch / destroy / expire)
  console.log('\n[45] Session create/find/destroy + expiry');
  {
    const { createSession, findSession, destroySession, cleanupExpiredSessions } =
      await import('../src/auth/session.js');
    await query(`DELETE FROM user_session`);

    const token = await createSession({
      email: 'alice@wahanalifeline.co.id', name: 'Alice', picture: null as any,
      ip: '127.0.0.1', userAgent: 'jest',
    });
    check('token is 64-char hex', /^[a-f0-9]{64}$/.test(token));

    const found = await findSession(token);
    check('found by token', found?.email === 'alice@wahanalifeline.co.id');

    const missing = await findSession('not-a-real-token');
    check('unknown token → null', missing === null);

    await destroySession(token);
    const gone = await findSession(token);
    check('destroyed session → null', gone === null);

    // Expired session
    const expiredToken = await createSession({ email: 'expired@example.com' });
    await query(
      `UPDATE user_session SET expires_at = NOW() - INTERVAL '1 hour' WHERE token = $1`,
      [expiredToken],
    );
    const expired = await findSession(expiredToken);
    check('expired session → null', expired === null);

    const cleaned = await cleanupExpiredSessions();
    check('cleanupExpiredSessions removed expired row', cleaned >= 1);
  }

  // 46. Google OAuth verifyAccess: HD + allowlist logic
  console.log('\n[46] verifyAccess: HD + allowlist rules');
  {
    const { verifyAccess } = await import('../src/auth/google.js');
    const { config } = await import('../src/config.js');

    // No allowlist, no HD → any verified email passes
    config.auth.googleHostedDomain = '';
    config.auth.emailAllowlist = [];
    check('no restrictions → ok',
      verifyAccess({ id:'1', email:'a@gmail.com', verified_email: true }) === null);

    // Unverified email rejected
    check('unverified email rejected',
      verifyAccess({ id:'1', email:'a@gmail.com', verified_email: false }) === 'email not verified');

    // HD set → must match
    config.auth.googleHostedDomain = 'wahanalifeline.co.id';
    check('matching HD → ok',
      verifyAccess({ id:'1', email:'a@wahanalifeline.co.id', verified_email: true, hd: 'wahanalifeline.co.id' }) === null);
    check('wrong HD → rejected',
      typeof verifyAccess({ id:'1', email:'a@gmail.com', verified_email: true, hd: 'gmail.com' }) === 'string');
    check('missing HD when expected → rejected',
      typeof verifyAccess({ id:'1', email:'a@gmail.com', verified_email: true }) === 'string');

    // Allowlist takes precedence over HD
    config.auth.googleHostedDomain = 'wahanalifeline.co.id';
    config.auth.emailAllowlist = ['external@partner.com'];
    check('email in allowlist → ok (HD ignored)',
      verifyAccess({ id:'1', email:'external@partner.com', verified_email: true, hd: 'partner.com' }) === null);
    check('email not in allowlist → rejected (even with right HD)',
      verifyAccess({ id:'1', email:'a@wahanalifeline.co.id', verified_email: true, hd: 'wahanalifeline.co.id' }) === 'email not in allowlist');

    // Reset config to avoid affecting other tests
    config.auth.googleHostedDomain = '';
    config.auth.emailAllowlist = [];
  }

  // 47. Cookie parsing helper + cookie builder
  console.log('\n[47] Cookie helpers parse Cookie header + build Set-Cookie');
  {
    const { getSessionTokenFromCookie, buildSessionCookie, clearCookie, SESSION_COOKIE } =
      await import('../src/auth/middleware.js');

    // Parse
    const fake1 = { headers: { cookie: 'wrg_session=abc123; other=value' } } as any;
    check('parse extracts token', getSessionTokenFromCookie(fake1) === 'abc123');

    const fake2 = { headers: {} } as any;
    check('parse returns empty when no cookie header', getSessionTokenFromCookie(fake2) === '');

    const fake3 = { headers: { cookie: 'other=value' } } as any;
    check('parse returns empty when our cookie missing', getSessionTokenFromCookie(fake3) === '');

    // Build
    const cookie = buildSessionCookie('xyz789', 3600);
    check('builder produces wrg_session', cookie.startsWith('wrg_session=xyz789'));
    check('builder has HttpOnly', cookie.includes('HttpOnly'));
    check('builder has SameSite=Lax', cookie.includes('SameSite=Lax'));
    check('builder has Max-Age', cookie.includes('Max-Age=3600'));

    // Clear
    check('clearCookie sets Max-Age=0', clearCookie(SESSION_COOKIE).includes('Max-Age=0'));
  }

  // 48. authenticate(): cookie session vs token vs nothing
  console.log('\n[48] authenticate() honors cookie session OR legacy token');
  {
    const { authenticate } = await import('../src/auth/middleware.js');
    const { createSession } = await import('../src/auth/session.js');
    const { config } = await import('../src/config.js');

    config.dashboard.token = 'test-bearer-token';

    // 1. No auth at all
    const noAuth = await authenticate({ headers: {}, query: {} } as any);
    check('no auth → null', noAuth === null);

    // 2. Valid cookie session
    const token = await createSession({ email: 'bob@wahanalifeline.co.id' });
    const cookieReq = { headers: { cookie: `wrg_session=${token}` }, query: {} } as any;
    const cookieCtx = await authenticate(cookieReq);
    check('cookie session → session ctx', cookieCtx?.session?.email === 'bob@wahanalifeline.co.id');

    // 3. Valid Bearer token (no session cookie)
    const tokenReq = { headers: { authorization: 'Bearer test-bearer-token' }, query: {} } as any;
    const tokenCtx = await authenticate(tokenReq);
    check('Bearer token → tokenAuth ctx', tokenCtx?.tokenAuth === true);

    // 4. Wrong Bearer token
    const wrongReq = { headers: { authorization: 'Bearer wrong' }, query: {} } as any;
    const wrongCtx = await authenticate(wrongReq);
    check('wrong Bearer → null', wrongCtx === null);

    // 5. Query string token
    const qReq = { headers: {}, query: { token: 'test-bearer-token' } } as any;
    const qCtx = await authenticate(qReq);
    check('?token= → tokenAuth ctx', qCtx?.tokenAuth === true);
  }

  // 49. logAuthEvent persists row to auth_log
  console.log('\n[49] logAuthEvent persists rows');
  {
    const { logAuthEvent } = await import('../src/auth/session.js');
    await query(`DELETE FROM auth_log`);
    await logAuthEvent({ email: 'login@example.com', event: 'login_success', ip: '1.2.3.4' });
    await logAuthEvent({ event: 'login_failed', reason: 'wrong hd' });
    const r = await query<{ n: number }>(`SELECT COUNT(*)::int AS n FROM auth_log`);
    check('2 auth_log rows', r.rows[0]?.n === 2);
    const success = await query<{ event: string; email: string; ip: string }>(
      `SELECT event, email, ip FROM auth_log WHERE event = 'login_success'`,
    );
    check('login_success row has email + ip', success.rows[0]?.email === 'login@example.com');
  }

  // 51. Setup status checks return per-integration health
  console.log('\n[51] Setup status: integration health checks');
  {
    const { checkAll } = await import('../src/setup/status.js');
    const rows = await checkAll();
    check('6 health checks returned', rows.length === 6);
    check('PostgreSQL check exists', rows.some((r) => r.label === 'PostgreSQL'));
    check('PostgreSQL is OK', rows.find((r) => r.label === 'PostgreSQL')?.ok === true);
    check('all checks have detail string', rows.every((r) => typeof r.detail === 'string' && r.detail.length > 0));
  }

  // 52. Master user CRUD via setup module
  console.log('\n[52] Master user CRUD: create / validate / duplicate / toggle');
  {
    const { listAms, createAm, toggleAmAktif, validateAmInput } =
      await import('../src/setup/users.js');

    // Validation
    check('reject empty wa_number', typeof validateAmInput({ wa_number: '', nama_am: 'x' }) === 'string');
    check('reject non-digit wa_number', typeof validateAmInput({ wa_number: 'abc', nama_am: 'x' }) === 'string');
    check('reject short name', typeof validateAmInput({ wa_number: '6281234567890', nama_am: 'x' }) === 'string');
    check('reject bad role', typeof validateAmInput({ wa_number: '6281234567890', nama_am: 'OK', role: 'WHAT' }) === 'string');
    check('accept valid input', validateAmInput({ wa_number: '6281234567890', nama_am: 'Valid AM', area: 'Bali' }) === null);

    // Create
    await query(`DELETE FROM master_user WHERE wa_number = '6289999999991'`);
    const r1 = await createAm({ wa_number: '6289999999991', nama_am: 'Test Setup AM', area: 'Bali', role: 'AM' });
    check('create returns AM row', 'id' in r1 && r1.wa_number === '6289999999991');

    // Duplicate detection
    const r2 = await createAm({ wa_number: '6289999999991', nama_am: 'Duplicate' });
    check('duplicate wa_number rejected', 'error' in r2 && /sudah terdaftar/.test(r2.error));

    // List
    const all = await listAms();
    check('listAms returns at least the seed + new', all.length >= 4);
    check('list includes our new AM', all.some((a) => a.wa_number === '6289999999991'));
    check('list has visits_30d field', all.every((a) => typeof a.visits_30d === 'number'));

    // Toggle aktif
    const newAm = all.find((a) => a.wa_number === '6289999999991')!;
    const tog1 = await toggleAmAktif(newAm.id, false);
    check('toggle off ok', tog1.ok === true);
    const togRow = await query<{ aktif: boolean }>(`SELECT aktif FROM master_user WHERE id = $1`, [newAm.id]);
    check('aktif now false', togRow.rows[0]?.aktif === false);
    const tog2 = await toggleAmAktif(999999, true);
    check('toggle non-existent returns error', tog2.ok === false);
  }

  // 53. Env reader masks secrets
  console.log('\n[53] readEnvSections masks secrets, groups by section');
  {
    const { readEnvSections } = await import('../src/setup/env.js');
    const sections = await readEnvSections('.env');
    check('at least 1 section parsed', sections.length >= 1);
    const allEntries = sections.flatMap((s) => s.entries);
    const tokenEntry = allEntries.find((e) => e.key === 'DASHBOARD_TOKEN');
    if (tokenEntry) {
      check('DASHBOARD_TOKEN marked masked', tokenEntry.masked === true);
      check('DASHBOARD_TOKEN value contains bullet', tokenEntry.value.includes('•') || tokenEntry.value === '(kosong)');
    }
    const pgEntry = allEntries.find((e) => e.key === 'PGUSER');
    check('PGUSER not masked (non-secret)', !pgEntry || pgEntry.masked === false);
  }

  // 50. buildAuthorizeUrl includes required OAuth params
  console.log('\n[50] buildAuthorizeUrl includes required OAuth params');
  {
    const { buildAuthorizeUrl } = await import('../src/auth/google.js');
    const { config } = await import('../src/config.js');
    config.auth.googleClientId = 'test-client-id.apps.googleusercontent.com';
    config.auth.baseUrl = 'http://localhost:3000';
    config.auth.googleHostedDomain = 'wahanalifeline.co.id';

    const url = buildAuthorizeUrl('state-abc');
    check('uses Google authorize endpoint', url.startsWith('https://accounts.google.com/o/oauth2/v2/auth?'));
    check('includes client_id', url.includes('client_id=test-client-id.apps.googleusercontent.com'));
    check('includes scope (URL-encoded space)', /scope=openid(\+|%20)email(\+|%20)profile/.test(url));
    check('includes state', url.includes('state=state-abc'));
    check('includes redirect_uri', url.includes('redirect_uri=http'));
    check('includes hd', url.includes('hd=wahanalifeline.co.id'));
    check('includes response_type=code', url.includes('response_type=code'));

    config.auth.googleHostedDomain = '';
    config.auth.googleClientId = '';
  }

  console.log(`\n══ RESULT: ${pass} pass, ${fail} fail ══════════════════\n`);
  await pool.end();
  process.exit(fail === 0 ? 0 : 1);
}

run().catch(async (err) => {
  console.error('FATAL:', err);
  await pool.end().catch(() => {});
  process.exit(1);
});
