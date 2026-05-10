/**
 * Shared parsing helpers for hashtag commands.
 * Pesan WA dapat berisi label key:value bertingkat, separator, dsb.
 */

/** Lowercase, trim, drop leading hash command line. */
export function bodyAfterHashtag(text: string, hashtag: string): string {
  const lower = text.trim();
  const re = new RegExp(`^${hashtag}\\b\\s*`, 'i');
  return lower.replace(re, '');
}

/** Find a `key: value` line (case-insensitive on the key). Multi-line value not supported here. */
export function getField(text: string, key: string): string | null {
  const re = new RegExp(`^\\s*${key}\\s*:\\s*(.+?)\\s*$`, 'im');
  const m = text.match(re);
  return m ? m[1].trim() : null;
}

/** Split a body by lines that contain only `---` (with optional spaces). */
export function splitByDashes(text: string): string[] {
  return text
    .split(/^\s*---+\s*$/m)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

/** Tujuan whitelist normalization for #PLAN. */
const TUJUAN_MAP: Array<[RegExp, string]> = [
  [/^(kunjungan(\s+fisik)?|visit|ktm)$/i, 'Kunjungan Fisik'],
  [/^(telepon|telp|call|tlp|telfon)$/i, 'Telepon'],
  [/^(wa|whatsapp|chat|msg)$/i, 'WA'],
  [/^(demo|demonstrasi)$/i, 'Demo'],
  [/^(presentasi|present|pitch)$/i, 'Presentasi'],
  [/^(follow[-\s]?up|fu|tl|fl)$/i, 'Follow-up'],
];
export function normalizeTujuan(input: string): string {
  const t = input.trim();
  for (const [re, val] of TUJUAN_MAP) if (re.test(t)) return val;
  return t;
}

/** Status whitelist normalization for #UPDATE. */
const STATUS_MAP: Record<string, 'Cold' | 'Warm' | 'Hot' | 'Won' | 'Lost'> = {
  cold: 'Cold',
  warm: 'Warm',
  hot: 'Hot',
  won: 'Won',
  lost: 'Lost',
};
export function normalizeStatus(input: string): 'Cold' | 'Warm' | 'Hot' | 'Won' | 'Lost' | null {
  return STATUS_MAP[input.trim().toLowerCase()] ?? null;
}

/** Truncate a string for compact reply lines, with ellipsis. */
export function truncate(s: string, max = 40): string {
  if (s.length <= max) return s;
  return s.slice(0, max).trimEnd() + '…';
}
