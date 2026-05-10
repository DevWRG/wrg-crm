/**
 * RFC 4180 CSV escaping + serializer.
 * Quoting rule: bila field mengandung `,` `"` `\r` `\n`, bungkus dengan
 * double-quote dan double-up tiap `"` di dalamnya. Else, biarkan polos.
 */

const NEEDS_QUOTE_RE = /[,"\r\n]/;

export function csvField(v: unknown): string {
  if (v === null || v === undefined) return '';
  const s = typeof v === 'string' ? v : String(v);
  if (!NEEDS_QUOTE_RE.test(s)) return s;
  return `"${s.replace(/"/g, '""')}"`;
}

export function csvRow(cells: unknown[]): string {
  return cells.map(csvField).join(',');
}

export interface CsvSerializeOpts<T> {
  headers: string[];
  rows: T[];
  /** Map a row to its cell array (in same order as headers). */
  row: (r: T) => unknown[];
  /** Optional BOM for Excel compatibility (default: true). */
  bom?: boolean;
}

export function serializeCsv<T>(opts: CsvSerializeOpts<T>): string {
  const lines: string[] = [];
  lines.push(csvRow(opts.headers));
  for (const r of opts.rows) lines.push(csvRow(opts.row(r)));
  // CRLF per RFC 4180. UTF-8 BOM optional (Excel needs it untuk recognize UTF-8).
  const body = lines.join('\r\n') + '\r\n';
  return (opts.bom !== false ? '﻿' : '') + body;
}

/** Build a downloadable filename like "wrg-pipeline-2026-05-11.csv". */
export function exportFilename(prefix: string, suffix = ''): string {
  const today = new Date().toISOString().slice(0, 10);
  const safe = prefix.replace(/[^a-z0-9-]/gi, '');
  return `wrg-${safe}${suffix ? '-' + suffix : ''}-${today}.csv`;
}
