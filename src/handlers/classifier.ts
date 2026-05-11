/**
 * Freeform message classifier.
 *
 * Ketika AM kirim pesan tanpa hashtag, classifier ini analisa via LLM untuk
 * deteksi intent. Kalau confidence tinggi → fire suggestion ke group:
 *   "💡 Sepertinya kamu mau lapor #REPORT untuk RS Pelita. Reply YA biar
 *    saya konversi otomatis."
 *
 * AM reply "ya"/"iya"/"sip"/"ok" → handler asli dijalankan dengan fields
 * yang sudah di-extract LLM. Sama mechanic dengan #UPDATE confirm flow.
 */

import { query } from '../db.js';
import { config } from '../config.js';
import { askJson, isConfigured as llmConfigured } from '../llm/openrouter.js';
import { handlePlan } from './plan.js';
import { handleReport } from './report.js';
import { handleLeads } from './leads.js';
import { handleUpdate } from './update.js';
import { todayWib } from '../util/dateid.js';
import type { HandlerResult, MasterUser } from '../types.js';

export type IntentKind = 'PLAN' | 'REPORT' | 'LEADS' | 'UPDATE' | 'NONE';

export interface ClassificationResult {
  intent: IntentKind;
  confidence: number;
  fields: Record<string, string>;
  reasoning: string;
}

/**
 * Pre-filter: skip LLM call untuk pesan yang jelas chit-chat / emoji-only /
 * confirm reply pattern. Heuristic, bukan validation — supaya hemat tokens.
 */
const SALES_KEYWORDS = [
  'kunjungan', 'visit', 'ketemu', 'meet', 'meeting', 'demo', 'presentasi',
  'tlp', 'telp', 'telepon', 'call', 'wa', 'whatsapp', 'follow',
  'rs ', 'rs.', 'klinik', 'lab ', 'apotek', 'puskesmas', 'dokter', 'dr.',
  'plan', 'rencana', 'besok', 'minggu depan', 'hari ini', 'kemarin', 'tadi',
  'pic ', 'produk', 'lead', 'lead baru', 'referal', 'referral',
  'stage', 'status', 'hot', 'warm', 'cold', 'won', 'lost', 'closed',
  'deal', 'po ', 'quotation', 'invoice',
];

const CONFIRM_REPLY_RE = /^\s*(ya|iya|yes|y|sip|ok|oke|okay|gas|jadiin|jadi|konversi)\s*$/i;
const HASHTAG_RE = /^\s*#\w+/;
const MIN_LEN = 25;

export function shouldClassify(text: string): boolean {
  if (!text || text.length < MIN_LEN) return false;
  if (HASHTAG_RE.test(text)) return false;
  if (CONFIRM_REPLY_RE.test(text)) return false;
  const lower = text.toLowerCase();
  // Must contain at least 1 sales-context keyword
  return SALES_KEYWORDS.some((kw) => lower.includes(kw));
}

export function isConfirmReplyPattern(text: string): boolean {
  return CONFIRM_REPLY_RE.test(text);
}

/** Build prompt for classifier. */
function buildClassifierPrompt(text: string, user: MasterUser): { system: string; user: string } {
  const today = todayWib();
  const system = `Kamu adalah classifier untuk pesan WhatsApp sales CRM Wahana Lifeline.
AM kadang lupa pakai hashtag — tugasmu deteksi maksud pesan + extract fields.

Output STRICT JSON saja (tanpa markdown fence, tanpa comment) dengan struktur:
{
  "intent": "PLAN" | "REPORT" | "LEADS" | "UPDATE" | "NONE",
  "confidence": <0.0 - 1.0>,
  "fields": {...},
  "reasoning": "<1 kalimat alasan kenapa intent ini>"
}

Definisi intent + required fields:
- PLAN     = rencana kunjungan AKAN datang (kata: "besok", "minggu depan", "tgl X", "akan visit")
             required: { "tgl": "DD/MM/YYYY", "cust": "<nama>", "tujuan": "<tujuan>", "goal": "<tujuan detail>" }
- REPORT   = laporan kunjungan SUDAH terjadi (kata: "tadi", "kemarin", "barusan", "sudah ketemu")
             required: { "cust": "<nama>", "hasil": "<hasil meeting>", "next": "<rencana followup>" }
- LEADS    = customer BARU dengan PIC/contact info
             required: { "cust": "<nama>", "pic": "<nama PIC (no telp)>", "tipe": "RS|Klinik|Lab|Apotek|dll", "produk": "<produk>", "info": "<konteks>" }
- UPDATE   = ubah stage/status pipeline customer EXISTING (kata: "naik stage", "jadi hot", "deal")
             required: { "cust": "<nama>", "stage": "<1-5>", "status": "Cold|Warm|Hot|Won|Lost", "note": "<catatan>" }
- NONE     = chit-chat, pertanyaan umum, emoji, ambigu

Rules:
- Tanggal relative: "besok" → ${today} + 1 hari (format DD/MM/YYYY), "hari ini" → ${formatToday(today)}, "kemarin" → ${today} - 1 hari
- "Tujuan" untuk PLAN: pilih dari Kunjungan Fisik / Telepon / WA / Demo / Presentasi / Follow-up (atau verbatim kalau gak match)
- Untuk UPDATE: kalau cust nggak pasti existing, intent jangan UPDATE
- Confidence < 0.65 → set intent=NONE
- Required field yang tidak ada di pesan: omit dari fields (jangan ngarang)
- Field "cust" wajib persis seperti yang ditulis user (jangan diubah huruf besar/kecil)

Context AM yang kirim: ${user.nama_am} (${user.area ?? 'unknown area'}).
Today: ${today}.`;

  return {
    system,
    user: `Pesan WA: """${text}"""`,
  };
}

function formatToday(yyyy_mm_dd: string): string {
  const [y, m, d] = yyyy_mm_dd.split('-');
  return `${d}/${m}/${y}`;
}

export async function classifyFreeform(
  text: string,
  user: MasterUser,
): Promise<ClassificationResult> {
  if (!llmConfigured()) {
    return { intent: 'NONE', confidence: 0, fields: {}, reasoning: 'LLM not configured' };
  }
  const prompt = buildClassifierPrompt(text, user);
  const r = await askJson<{
    intent: IntentKind;
    confidence: number;
    fields: Record<string, string>;
    reasoning?: string;
  }>({
    system: prompt.system,
    user: prompt.user,
    temperature: 0.2,
    maxTokens: 300,
  });
  if (!r.ok || !r.json) {
    return { intent: 'NONE', confidence: 0, fields: {}, reasoning: 'parse failed' };
  }
  const intent = (r.json.intent ?? 'NONE') as IntentKind;
  const confidence = Math.max(0, Math.min(1, Number(r.json.confidence ?? 0)));
  return {
    intent,
    confidence,
    fields: r.json.fields ?? {},
    reasoning: r.json.reasoning ?? '',
  };
}

/** Build hashtag text from classifier fields, ready to feed handlers. */
export function buildHashtagFromIntent(c: ClassificationResult): string | null {
  const f = c.fields;
  switch (c.intent) {
    case 'PLAN':
      if (!f.cust || !f.tgl) return null;
      return [
        '#PLAN',
        `tgl: ${f.tgl}`,
        `cust: ${f.cust}`,
        f.tujuan ? `tujuan: ${f.tujuan}` : null,
        f.goal ? `goal: ${f.goal}` : null,
      ].filter(Boolean).join('\n');
    case 'REPORT':
      if (!f.cust) return null;
      return [
        '#REPORT',
        `cust: ${f.cust}`,
        f.hasil ? `hasil: ${f.hasil}` : null,
        f.next ? `next: ${f.next}` : null,
      ].filter(Boolean).join('\n');
    case 'LEADS':
      if (!f.cust || !f.pic || !f.tipe || !f.produk || !f.info) return null;
      return [
        '#LEADS',
        `cust: ${f.cust}`,
        `pic: ${f.pic}`,
        `tipe: ${f.tipe}`,
        `produk: ${f.produk}`,
        `info: ${f.info}`,
      ].join('\n');
    case 'UPDATE':
      if (!f.cust || !f.stage || !f.status) return null;
      return [
        '#UPDATE',
        `cust: ${f.cust}`,
        `stage: ${f.stage}`,
        `status: ${f.status}`,
        f.note ? `note: ${f.note}` : null,
      ].filter(Boolean).join('\n');
    default:
      return null;
  }
}

/** Format the suggestion message (sent to GROUP for visibility). */
function formatSuggestion(c: ClassificationResult): string {
  const f = c.fields;
  const intent = c.intent;
  const lines: string[] = [];
  lines.push(`💡 *Sepertinya ini mau di-#${intent}* (${Math.round(c.confidence * 100)}% yakin)`);
  if (f.cust) lines.push(`👤 ${f.cust}`);
  if (intent === 'PLAN') {
    if (f.tgl) lines.push(`📅 ${f.tgl}`);
    if (f.tujuan) lines.push(`🎯 ${f.tujuan}`);
    if (f.goal) lines.push(`📝 ${f.goal}`);
  } else if (intent === 'REPORT') {
    if (f.hasil) lines.push(`✅ ${f.hasil}`);
    if (f.next) lines.push(`➡️ ${f.next}`);
  } else if (intent === 'LEADS') {
    if (f.pic) lines.push(`📞 ${f.pic}`);
    if (f.tipe) lines.push(`🏥 ${f.tipe}`);
    if (f.produk) lines.push(`📦 ${f.produk}`);
    if (f.info) lines.push(`ℹ️ ${f.info}`);
  } else if (intent === 'UPDATE') {
    if (f.stage) lines.push(`📊 Stage ${f.stage}`);
    if (f.status) lines.push(`🏷️ ${f.status}`);
    if (f.note) lines.push(`📝 ${f.note}`);
  }
  lines.push('');
  lines.push('Reply *YA* untuk konversi otomatis, atau abaikan (expired 10 menit).');
  return lines.join('\n');
}

/**
 * Try to classify + suggest. Returns HandlerResult kalau LLM detect intent
 * dengan confidence >= threshold AND fields sufficient. Returns null kalau:
 * - LLM disabled
 * - intent=NONE atau confidence rendah
 * - fields tidak cukup untuk build hashtag
 */
export async function tryClassifyAndSuggest(
  user: MasterUser,
  text: string,
): Promise<HandlerResult | null> {
  if (!config.llm.freeformParserEnabled) return null;
  if (!shouldClassify(text)) return null;

  const result = await classifyFreeform(text, user);
  if (result.intent === 'NONE') return null;
  if (result.confidence < config.llm.freeformConfidence) return null;

  const hashtagText = buildHashtagFromIntent(result);
  if (!hashtagText) return null;

  // Persist pending so we can execute on AM's "ya" reply.
  await query(
    `INSERT INTO pending_confirm (wa_number, hashtag, candidates, payload)
     VALUES ($1, $2, '[]'::jsonb, $3::jsonb)`,
    [user.wa_number, '#SUGGEST', JSON.stringify({ intent: result.intent, hashtagText, classification: result })],
  );

  return {
    status: 'CONFIRM_NEEDED',
    customerCount: 0,
    payload: { freeform: true, intent: result.intent, fields: result.fields, confidence: result.confidence },
    replies: [{ to: 'group', target: '', text: formatSuggestion(result) }],
  };
}

/**
 * Handle "ya/iya/sip/ok" reply against a recent #SUGGEST pending.
 * Returns HandlerResult kalau pending ditemukan + intent dieksekusi.
 * Returns null kalau bukan confirm pattern atau tidak ada pending.
 */
export async function tryHandleSuggestReply(
  user: MasterUser,
  text: string,
): Promise<HandlerResult | null> {
  if (!isConfirmReplyPattern(text)) return null;

  const pending = await query<{
    id: number;
    payload: { intent: IntentKind; hashtagText: string; classification: ClassificationResult };
  }>(
    `SELECT id, payload FROM pending_confirm
      WHERE wa_number = $1 AND hashtag = '#SUGGEST' AND expires_at > NOW()
      ORDER BY created_at DESC LIMIT 1`,
    [user.wa_number],
  );
  const row = pending.rows[0];
  if (!row) return null;

  // Delete pending immediately to prevent double-execute
  await query(`DELETE FROM pending_confirm WHERE id = $1`, [row.id]);

  const { intent, hashtagText } = row.payload;
  let result: HandlerResult;
  try {
    switch (intent) {
      case 'PLAN':   result = await handlePlan(user, hashtagText); break;
      case 'REPORT': result = await handleReport(user, hashtagText); break;
      case 'LEADS':  result = await handleLeads(user, hashtagText); break;
      case 'UPDATE': result = await handleUpdate(user, hashtagText); break;
      default:
        return {
          status: 'FAILED',
          customerCount: 0,
          payload: { error: 'unknown intent', intent },
          replies: [{ to: 'dm', target: '', text: `❌ Intent tidak dikenal: ${intent}` }],
          error: 'unknown intent',
        };
    }
  } catch (err) {
    const message = (err as Error).message || 'Unknown error';
    return {
      status: 'FAILED',
      customerCount: 0,
      payload: { error: message, intent, hashtagText },
      replies: [{ to: 'dm', target: '', text: `❌ Gagal eksekusi #${intent} dari suggestion: ${message}` }],
      error: message,
    };
  }
  return result;
}
