import { formatDateId } from '../util/dateid.js';
import { truncate } from '../util/parse.js';
import { ask, isConfigured as llmConfigured } from '../llm/openrouter.js';
import type { SummaryData } from './queries.js';

export { narrativeTemplate };

const DIVIDER = '────────────────────';

function bullet(items: string[], emptyText: string): string {
  if (items.length === 0) return `• ${emptyText}`;
  return items.map((i) => `• ${i}`).join('\n');
}

/** Template-based fallback (dipakai kalau LLM mati / tidak di-config). */
function narrativeTemplate(d: SummaryData): string {
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

/**
 * AI-powered narrative via OpenRouter. LLM dikasih data summary mentah,
 * diminta tulis 2-3 kalimat eksekutif Bahasa Indonesia untuk HOD.
 * Kalau LLM gagal/tidak configured, fallback ke template.
 *
 * Sengaja async — tapi kalau caller mau sync, pakai narrativeTemplate.
 */
async function narrativeAi(d: SummaryData): Promise<string> {
  if (!llmConfigured()) return narrativeTemplate(d);

  const hotDealsList = d.hotDeals
    .slice(0, 5)
    .map((h) => `- ${h.customer_name} (${h.nama_am}) stage ${h.stage} ${h.status}${h.note ? ': ' + h.note.slice(0, 80) : ''}`)
    .join('\n') || '(tidak ada)';
  const attentionList = d.needAttention
    .slice(0, 5)
    .map((a) => `- ${a.nama_am} (${a.area ?? '-'}): ${a.plans} plan, ${a.visits} visit`)
    .join('\n') || '(semua AM aktif)';
  const topPerformerList = d.topPerformers
    .map((t) => `- ${t.nama_am}: ${t.visits} visit`)
    .join('\n') || '(belum ada)';

  const userPrompt = `Tanggal: ${d.tanggal}
Tim Aktif: ${d.activeTeamCount}/${d.totalAmRoster}
Total Visit: ${d.totalVisits}
Total Plan: ${d.totalPlans}
Coverage: ${d.coveragePct}%

Hot Deals (yang updated hari ini):
${hotDealsList}

Perlu perhatian:
${attentionList}

Top performer:
${topPerformerList}`;

  const result = await ask({
    system:
      'Kamu adalah analis sales untuk WRG CRM. Tulis ringkasan 2-3 kalimat dalam Bahasa Indonesia ' +
      'untuk Head of Department dari raw data harian. Tone profesional tapi tidak kaku. ' +
      'Highlight engagement, coverage plan, deal panas, dan AM yang butuh perhatian. ' +
      'Berikan tone "actionable insight" — bukan sekadar copy angka. Maksimal 60 kata. ' +
      'JANGAN pakai bullet point, JANGAN pakai header, JANGAN ulang angka mentah, output 2-3 kalimat polos.',
    user: userPrompt,
    temperature: 0.4,
    maxTokens: 200,
  });

  if (!result.ok || !result.text) return narrativeTemplate(d);
  return result.text;
}

export async function generateNarrative(d: SummaryData): Promise<string> {
  return narrativeAi(d);
}

export async function renderDailySummary(d: SummaryData): Promise<string> {
  const narrativeText = await generateNarrative(d);
  return renderDailySummaryWithNarrative(d, narrativeText);
}

/**
 * Sync render — caller kasih narrative sendiri (atau pakai default
 * `narrativeTemplate`). Dipakai untuk tests yang gak mau LLM call.
 */
export function renderDailySummaryWithNarrative(d: SummaryData, narrativeText: string): string {
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
    narrativeText,
    DIVIDER,
    `WRG CRM v4 | OpenClaw + RTK`,
  ].join('\n');
}
