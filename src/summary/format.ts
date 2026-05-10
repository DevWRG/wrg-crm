import { formatDateId } from '../util/dateid.js';
import { truncate } from '../util/parse.js';
import type { SummaryData } from './queries.js';

const DIVIDER = '────────────────────';

function bullet(items: string[], emptyText: string): string {
  if (items.length === 0) return `• ${emptyText}`;
  return items.map((i) => `• ${i}`).join('\n');
}

function narrative(d: SummaryData): string {
  const { activeTeamCount, totalAmRoster, coveragePct, totalVisits, totalPlans } = d;

  if (totalAmRoster === 0) return 'Roster AM kosong — cek master_user.';
  if (totalPlans === 0 && totalVisits === 0) {
    return 'Belum ada aktivitas tercatat hari ini. Pastikan tim mengirim #PLAN dan #REPORT lewat WA.';
  }

  const teamPct = Math.round((activeTeamCount / totalAmRoster) * 100);
  const parts: string[] = [];

  if (teamPct >= 80) parts.push(`Engagement tim solid (${teamPct}% aktif)`);
  else if (teamPct >= 50) parts.push(`Engagement tim cukup (${teamPct}% aktif)`);
  else parts.push(`Engagement tim rendah (hanya ${teamPct}% aktif)`);

  if (totalPlans > 0) {
    if (coveragePct >= 80) parts.push(`coverage plan ${coveragePct}% — eksekusi rapih`);
    else if (coveragePct >= 50) parts.push(`coverage plan ${coveragePct}% — masih ada plan yang terlewat`);
    else parts.push(`coverage plan baru ${coveragePct}% — banyak plan belum dieksekusi`);
  }

  if (d.hotDeals.length > 0) {
    parts.push(`${d.hotDeals.length} deal panas patut difollow-up cepat`);
  }
  if (d.needAttention.length > 0) {
    parts.push(`${d.needAttention.length} AM perlu didorong besok`);
  }

  return parts.join('. ') + '.';
}

export function renderDailySummary(d: SummaryData): string {
  const dateLabel = formatDateId(d.tanggal);

  const hotLines = d.hotDeals.map((h) => {
    const upd = h.note ? truncate(h.note, 50) : `${h.status} stage ${h.stage}`;
    return `${h.customer_name} (${h.nama_am}) — ${upd}`;
  });

  const attentionLines = d.needAttention.map((a) => {
    if (a.plans > 0) return `${a.nama_am} (${a.area ?? '-'}) — ${a.plans} plan, 0 kunjungan`;
    return `${a.nama_am} (${a.area ?? '-'}) — 0 kunjungan`;
  });

  const topLines =
    d.topPerformers.length === 0
      ? ['Belum ada kunjungan tercatat hari ini']
      : d.topPerformers.map((t) => `${t.nama_am} — ${t.visits} kunjungan`);

  return [
    `📊 *Daily CRM Summary — ${dateLabel}*`,
    DIVIDER,
    `👥 Tim Aktif: ${d.activeTeamCount}/${d.totalAmRoster}`,
    `📋 Total Kunjungan: ${d.totalVisits}  |  Plan: ${d.totalPlans}  |  Coverage: ${d.coveragePct}%`,
    '',
    `🔥 Hot Deals:`,
    bullet(hotLines, 'Belum ada deal Hot/stage 3+ hari ini'),
    '',
    `⚠️ Perlu Perhatian:`,
    bullet(attentionLines, 'Semua AM aktif — mantap!'),
    '',
    `📈 Top Performer:`,
    bullet(topLines, ''),
    '',
    `📝 Summary:`,
    narrative(d),
    DIVIDER,
    `WRG CRM v4 | OpenClaw + RTK`,
  ].join('\n');
}
