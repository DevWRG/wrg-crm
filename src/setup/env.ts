/**
 * Read .env file from disk + return parsed values dengan secret masking.
 * Read-only — editing .env dari web tidak aman (bisa rusak config), user
 * disuruh edit manual dengan instruksi yang dikasih.
 */

import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const SECRET_KEYS = new Set([
  'PGPASSWORD',
  'WA_SEND_TOKEN',
  'DASHBOARD_TOKEN',
  'OAUTH_GOOGLE_CLIENT_SECRET',
  'SMTP_PASS',
  'ALERT_WEBHOOK_URL', // bisa contain Slack token in path
]);

export interface EnvEntry {
  key: string;
  value: string;
  /** True kalau key di SECRET_KEYS → value sudah di-mask. */
  masked: boolean;
  /** Comment (line yang diawali `#`) di atas key. */
  comment: string | null;
}

export interface EnvSection {
  title: string;
  entries: EnvEntry[];
}

function maskValue(v: string): string {
  if (!v) return '(kosong)';
  if (v.length <= 8) return '•'.repeat(v.length);
  return v.slice(0, 4) + '•'.repeat(Math.max(8, v.length - 8)) + v.slice(-4);
}

/**
 * Parse `.env`-style file. Bentuk:
 *   # comment line, jadi section title kalau diawali `# ── ... ─` style
 *   KEY=value
 * Group entry berdasarkan baris comment terakhir (jadi section heading).
 */
export async function readEnvSections(envPath = '.env'): Promise<EnvSection[]> {
  const path = resolve(process.cwd(), envPath);
  let raw: string;
  try {
    raw = await readFile(path, 'utf8');
  } catch {
    return [];
  }

  const sections: EnvSection[] = [];
  let current: EnvSection = { title: 'General', entries: [] };
  let pendingComment: string | null = null;

  for (const line of raw.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;

    if (trimmed.startsWith('#')) {
      const text = trimmed.replace(/^#+\s*/, '').replace(/[─=]+/g, '').trim();
      // Heuristik: kalau ada karakter "──" di asli line atau prefix `# ── `, itu section.
      if (line.includes('──') || /^#\s*[A-Z]/.test(trimmed)) {
        if (current.entries.length > 0) sections.push(current);
        current = { title: text || 'Section', entries: [] };
        pendingComment = null;
      } else {
        pendingComment = text;
      }
      continue;
    }

    const m = trimmed.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (!m) continue;
    const [, key, rawValue] = m;
    const value = rawValue.replace(/^["']|["']$/g, '');
    const isSecret = SECRET_KEYS.has(key);
    current.entries.push({
      key,
      value: isSecret ? maskValue(value) : value || '(kosong)',
      masked: isSecret,
      comment: pendingComment,
    });
    pendingComment = null;
  }
  if (current.entries.length > 0) sections.push(current);
  return sections;
}
