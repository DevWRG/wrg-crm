/**
 * Weekly digest: print-friendly HTML page. HOD bisa cetak ke PDF via
 * print dialog browser (Cmd+P → Save as PDF). Tidak butuh server-side
 * PDF renderer.
 */

import { query } from '../db.js';
import { formatDateId } from '../util/dateid.js';
import { fetchSummary } from '../summary/queries.js';
import { exportPipeline } from './queries.js';

function esc(s: unknown): string {
  if (s === null || s === undefined) return '';
  return String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function pillFor(status: string): string {
  return `<span class="pill ${status.toLowerCase()}">${esc(status)}</span>`;
}

export async function renderWeeklyDigest(weekStart: string, weekEnd: string): Promise<string> {
  // Per-day summaries dalam range minggu
  const dayRange = await query<{
    tanggal: string;
    visits: number;
    plans: number;
    active_am: number;
  }>(
    `WITH days AS (
       SELECT generate_series($1::date, $2::date, INTERVAL '1 day')::date AS d
     )
     SELECT to_char(days.d, 'YYYY-MM-DD') AS tanggal,
            COALESCE(v.n, 0)::int AS visits,
            COALESCE(p.n, 0)::int AS plans,
            COALESCE(v.am, 0)::int AS active_am
       FROM days
       LEFT JOIN (
         SELECT tanggal, COUNT(*)::int AS n, COUNT(DISTINCT user_id)::int AS am
           FROM activity_log
          WHERE tanggal BETWEEN $1::date AND $2::date
          GROUP BY tanggal
       ) v ON v.tanggal = days.d
       LEFT JOIN (
         SELECT tanggal, COUNT(*)::int AS n FROM sales_plan
          WHERE tanggal BETWEEN $1::date AND $2::date
          GROUP BY tanggal
       ) p ON p.tanggal = days.d
       ORDER BY days.d`,
    [weekStart, weekEnd],
  );

  // Aggregate per-AM untuk minggu ini
  const perAm = await query<{
    nama_am: string; area: string | null; visits: number; plans: number;
  }>(
    `SELECT mu.nama_am, mu.area,
            COALESCE(v.n, 0)::int AS visits,
            COALESCE(p.n, 0)::int AS plans
       FROM master_user mu
       LEFT JOIN (
         SELECT user_id, COUNT(*)::int AS n FROM activity_log
          WHERE tanggal BETWEEN $1::date AND $2::date
          GROUP BY user_id
       ) v ON v.user_id = mu.id
       LEFT JOIN (
         SELECT user_id, COUNT(*)::int AS n FROM sales_plan
          WHERE tanggal BETWEEN $1::date AND $2::date
          GROUP BY user_id
       ) p ON p.user_id = mu.id
      WHERE mu.aktif = TRUE AND mu.role = 'AM'
      ORDER BY visits DESC, plans DESC, mu.nama_am`,
    [weekStart, weekEnd],
  );

  // Closed deals minggu ini
  const closed = await query<{
    customer_name: string; nama_am: string; produk: string | null;
    nilai_deal: string | null; tanggal_closed: string;
  }>(
    `SELECT dc.customer_name, mu.nama_am, dc.produk,
            dc.nilai_deal::text AS nilai_deal,
            to_char(dc.tanggal_closed, 'YYYY-MM-DD') AS tanggal_closed
       FROM deal_closed dc
       JOIN master_user mu ON mu.id = dc.user_id
      WHERE dc.tanggal_closed BETWEEN $1::date AND $2::date
      ORDER BY dc.tanggal_closed DESC, mu.nama_am`,
    [weekStart, weekEnd],
  );

  const pipeline = await exportPipeline();
  const pipelineHot = pipeline.filter((p) => p.status === 'Hot' || p.stage >= 3).slice(0, 20);

  // Today summary used for headline numbers
  const todaySummary = await fetchSummary(weekEnd);

  const totalVisits = dayRange.rows.reduce((s, r) => s + r.visits, 0);
  const totalPlans = dayRange.rows.reduce((s, r) => s + r.plans, 0);
  const avgActiveAm =
    dayRange.rows.length > 0
      ? Math.round(dayRange.rows.reduce((s, r) => s + r.active_am, 0) / dayRange.rows.length)
      : 0;
  const totalRevenue = closed.rows.reduce(
    (s, r) => s + parseFloat(r.nilai_deal || '0'),
    0,
  );

  const dayHtml = dayRange.rows
    .map((d) => {
      const cov = d.plans > 0 ? Math.round((d.visits / d.plans) * 100) : 0;
      return `<tr><td>${formatDateId(d.tanggal)}</td><td>${d.active_am}</td>` +
        `<td>${d.visits}</td><td>${d.plans}</td><td>${cov}%</td></tr>`;
    })
    .join('');

  const amHtml = perAm.rows
    .map((a) => `<tr><td>${esc(a.nama_am)}</td><td>${esc(a.area || '-')}</td>` +
      `<td>${a.visits}</td><td>${a.plans}</td></tr>`)
    .join('');

  const closedHtml = closed.rows.length
    ? closed.rows
        .map(
          (c) => `<tr><td>${esc(c.customer_name)}</td><td>${esc(c.nama_am)}</td>` +
            `<td>${esc(c.produk || '-')}</td><td>${esc(c.nilai_deal || '-')}</td>` +
            `<td>${formatDateId(c.tanggal_closed)}</td></tr>`,
        )
        .join('')
    : `<tr><td colspan="5" class="empty">Belum ada deal closed di minggu ini</td></tr>`;

  const hotHtml = pipelineHot.length
    ? pipelineHot
        .map(
          (p) => `<tr><td>${esc(p.customer_name)}</td><td>${esc(p.nama_am)}</td>` +
            `<td>${esc(p.produk || '-')}</td><td>${p.stage}</td><td>${pillFor(p.status)}</td></tr>`,
        )
        .join('')
    : `<tr><td colspan="5" class="empty">Tidak ada deal panas di pipeline</td></tr>`;

  return `<!DOCTYPE html>
<html lang="id"><head><meta charset="UTF-8"><title>WRG Weekly Digest ${weekStart} → ${weekEnd}</title>
<style>
  @page { margin: 1.5cm; }
  body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    color: #1a1a1a; max-width: 900px; margin: 24px auto; padding: 0 24px; font-size: 13px; line-height: 1.5; }
  h1 { font-size: 20px; margin: 0 0 4px 0; }
  h1 .sub { color: #666; font-weight: 400; font-size: 14px; }
  h2 { font-size: 14px; text-transform: uppercase; letter-spacing: 0.05em;
    color: #444; border-bottom: 1px solid #ddd; padding-bottom: 4px; margin-top: 24px; }
  .kpi-grid { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin: 16px 0; }
  .kpi { border: 1px solid #ddd; border-radius: 6px; padding: 10px 14px; }
  .kpi .label { font-size: 11px; color: #666; text-transform: uppercase; letter-spacing: 0.05em; }
  .kpi .val { font-size: 22px; font-weight: 600; margin-top: 2px; }
  table { width: 100%; border-collapse: collapse; margin: 8px 0 16px; font-size: 12px; }
  th { text-align: left; background: #f5f5f5; padding: 6px 8px; border-bottom: 1px solid #ddd;
    font-weight: 600; font-size: 11px; }
  td { padding: 5px 8px; border-bottom: 1px solid #eee; vertical-align: top; }
  .pill { display: inline-block; padding: 1px 8px; border-radius: 10px; font-size: 10px; font-weight: 600; }
  .pill.cold { background: #dbeafe; color: #1e40af; }
  .pill.warm { background: #fef3c7; color: #92400e; }
  .pill.hot { background: #fee2e2; color: #b91c1c; }
  .pill.won { background: #d1fae5; color: #065f46; }
  .pill.lost { background: #e5e7eb; color: #374151; }
  .empty { color: #888; font-style: italic; }
  footer { margin-top: 32px; padding-top: 12px; border-top: 1px solid #ddd;
    color: #888; font-size: 11px; text-align: center; }
  @media print {
    body { margin: 0; padding: 0; max-width: 100%; }
    h2 { page-break-after: avoid; }
    tr, table { page-break-inside: avoid; }
  }
</style></head><body>
<h1>WRG Weekly Digest <span class="sub">${formatDateId(weekStart)} → ${formatDateId(weekEnd)}</span></h1>

<div class="kpi-grid">
  <div class="kpi"><div class="label">Total Visits</div><div class="val">${totalVisits}</div></div>
  <div class="kpi"><div class="label">Total Plans</div><div class="val">${totalPlans}</div></div>
  <div class="kpi"><div class="label">Avg Active AM/day</div><div class="val">${avgActiveAm}/${todaySummary.totalAmRoster}</div></div>
  <div class="kpi"><div class="label">Revenue (closed)</div><div class="val">${totalRevenue ? totalRevenue.toLocaleString('id-ID') : '—'}</div></div>
</div>

<h2>Daily Breakdown</h2>
<table><thead><tr><th>Tanggal</th><th>Active AM</th><th>Visits</th><th>Plans</th><th>Coverage</th></tr></thead><tbody>${dayHtml}</tbody></table>

<h2>Per-AM (Minggu Ini)</h2>
<table><thead><tr><th>AM</th><th>Area</th><th>Visits</th><th>Plans</th></tr></thead><tbody>${amHtml}</tbody></table>

<h2>Deals Closed</h2>
<table><thead><tr><th>Customer</th><th>AM</th><th>Produk</th><th>Nilai</th><th>Tanggal</th></tr></thead><tbody>${closedHtml}</tbody></table>

<h2>Hot Pipeline (Stage ≥ 3 or Status = Hot)</h2>
<table><thead><tr><th>Customer</th><th>AM</th><th>Produk</th><th>Stage</th><th>Status</th></tr></thead><tbody>${hotHtml}</tbody></table>

<footer>WRG CRM v4 — Weekly Digest — Generated ${new Date().toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })} WIB<br/>
Cetak ke PDF: Cmd+P (Mac) atau Ctrl+P (Windows) → Save as PDF</footer>
</body></html>`;
}
