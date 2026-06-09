#!/usr/bin/env node
/**
 * Regenerate README dashboard screenshots dari WRG CRM dashboard (dev :8092).
 *
 * Prasyarat:
 *   - dashboard dev jalan di http://localhost:8092
 *   - dev DB sudah di-seed demo data (scripts/seed_demo_data.py), periode 4–22 Mei
 *   - .service_token ada di repo root (untuk auth bypass login)
 *
 * Output: docs/images/dashboard-{main,trend,hod,drilldown}.png
 * Jalankan dari folder frontend/ supaya playwright ke-resolve:
 *   node scripts/wrg-readme-shots.mjs
 */
import { chromium } from 'playwright';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(__dirname, '..', '..');
const IMG = resolve(ROOT, 'docs', 'images');
const BASE = process.env.BASE_URL || 'http://localhost:8092';
const TOKEN = (process.env.WRG_SERVICE_TOKEN || readFileSync(resolve(ROOT, '.service_token'), 'utf8')).trim();
const RANGE = 'from=2026-05-04&to=2026-05-22';   // rentang demo data
const DRILL_UID = process.env.DRILL_UID || '10'; // AM contoh utk drilldown (Angga, Madura)

const settle = (page, ms = 1800) => page.waitForTimeout(ms);

(async () => {
  const browser = await chromium.launch({ channel: 'chrome' });
  const ctx = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: 2,
  });
  const page = await ctx.newPage();

  // 1. Service-login → set cookie + redirect ke dashboard.
  const next = encodeURIComponent(`/?${RANGE}`);
  process.stdout.write('login... ');
  await page.goto(`${BASE}/api/auth/service-login?token=${TOKEN}&next=${next}`,
    { waitUntil: 'domcontentloaded', timeout: 30000 });
  await settle(page);
  console.log('ok');

  // 2. Main view (tab Per Orang default).
  await page.goto(`${BASE}/?${RANGE}`, { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForSelector('#wrgTrenChart', { timeout: 15000 });
  await settle(page);
  // Frontend default range = minggu berjalan; set range ke periode demo via UI.
  await page.fill('#dateFrom', '2026-05-04');
  await page.fill('#dateTo', '2026-05-22');
  await page.click('#btnApply');
  await settle(page, 2500);   // tunggu refetch + chart re-render
  // Sembunyikan reminder widget + tinggiin viewport supaya tabel per-orang ikut ke-capture.
  await page.getByText('Sembunyikan', { exact: false }).first().click().catch(() => {});
  await settle(page, 500);
  await page.setViewportSize({ width: 1440, height: 1750 });
  await settle(page, 600);
  await page.screenshot({ path: resolve(IMG, 'dashboard-main.png'), fullPage: false });
  console.log('  saved dashboard-main.png');
  await page.setViewportSize({ width: 1440, height: 900 });   // balikin utk shot lain

  // 3. Trend chart card (fokus).
  await page.locator('section.card:has(#wrgTrenChart)').screenshot({
    path: resolve(IMG, 'dashboard-trend.png'),
  });
  console.log('  saved dashboard-trend.png');

  // 4. Tab Per HOD Sales.
  await page.click('[data-tab="hod"]');
  await settle(page, 1500);
  await page.screenshot({ path: resolve(IMG, 'dashboard-hod.png'), fullPage: false });
  console.log('  saved dashboard-hod.png');

  // 5. Drilldown — halaman detail per orang (redesign: navigate, bukan modal).
  await page.goto(`${BASE}/drilldown.html?user_id=${DRILL_UID}`,
    { waitUntil: 'domcontentloaded', timeout: 30000 });
  await page.waitForSelector('#dateFrom', { timeout: 15000 });
  await page.fill('#dateFrom', '2026-05-04');
  await page.fill('#dateTo', '2026-05-22');
  await page.click('#btnApply');
  await settle(page, 2500);
  await page.screenshot({ path: resolve(IMG, 'dashboard-drilldown.png'), fullPage: false });
  console.log('  saved dashboard-drilldown.png');

  await browser.close();
  console.log('Done.');
})().catch((e) => { console.error(e); process.exit(1); });
