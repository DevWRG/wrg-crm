import dayjs from 'dayjs';
import 'dayjs/locale/id.js';
import utc from 'dayjs/plugin/utc.js';
import timezone from 'dayjs/plugin/timezone.js';
import customParseFormat from 'dayjs/plugin/customParseFormat.js';

dayjs.extend(utc);
dayjs.extend(timezone);
dayjs.extend(customParseFormat);
dayjs.locale('id');

const TZ = 'Asia/Jakarta';

const BULAN_ID = [
  'Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni',
  'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember',
];

/** Parse "DD/MM/YYYY" → ISO date string "YYYY-MM-DD" or throw. */
export function parseDmy(input: string): string {
  const m = input.trim().match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (!m) throw new Error(`Format tanggal harus DD/MM/YYYY (contoh 01/05/2026), dapat: "${input}"`);
  const [, dd, mm, yyyy] = m;
  const d = dayjs.tz(`${yyyy}-${mm.padStart(2, '0')}-${dd.padStart(2, '0')}`, 'YYYY-MM-DD', TZ);
  if (!d.isValid()) throw new Error(`Tanggal tidak valid: "${input}"`);
  return d.format('YYYY-MM-DD');
}

/** "YYYY-MM-DD" or Date → "01 Mei 2026" */
export function formatDateId(input: string | Date): string {
  const d = dayjs.tz(input as string, TZ);
  return `${String(d.date()).padStart(2, '0')} ${BULAN_ID[d.month()]} ${d.year()}`;
}

/** Today as "YYYY-MM-DD" in WIB. */
export function todayWib(): string {
  return dayjs().tz(TZ).format('YYYY-MM-DD');
}
