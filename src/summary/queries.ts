import { query } from '../db.js';

export interface ActivityRow {
  customer_name: string;
  tujuan: string | null;
  hasil: string | null;
  next_action: string | null;
  nama_am: string;
  area: string | null;
}

export interface AmStatRow {
  user_id: number;
  nama_am: string;
  area: string | null;
  visits: number;
  plans: number;
}

export interface HotDealRow {
  customer_name: string;
  nama_am: string;
  stage: number;
  status: string;
  note: string | null;
  updated_at: string;
}

export interface SummaryData {
  tanggal: string;                  // YYYY-MM-DD
  totalAmRoster: number;            // total active AMs (denominator for "X/N")
  activeTeamCount: number;          // distinct AMs with ≥1 activity today
  totalVisits: number;
  totalPlans: number;
  coveragePct: number;              // 0-100
  hotDeals: HotDealRow[];
  needAttention: AmStatRow[];       // AM with 0 visits (atau plans terlewat)
  topPerformers: AmStatRow[];       // top 1-3 by visit count today
  amStats: AmStatRow[];             // all AMs with stats
}

/**
 * Fetch all summary data for a given date (YYYY-MM-DD, WIB).
 * Pass null/undefined to use today (WIB).
 */
export async function fetchSummary(tanggal: string): Promise<SummaryData> {
  // Total active AM roster (people with role='AM' and aktif)
  const rosterRes = await query<{ n: number }>(
    `SELECT COUNT(*)::int AS n
       FROM master_user
      WHERE aktif = TRUE AND role = 'AM'`,
  );
  const totalAmRoster = rosterRes.rows[0]?.n ?? 0;

  // Per-AM stats: visits + plans for the date.
  const amStatsRes = await query<AmStatRow>(
    `WITH am AS (
       SELECT id AS user_id, nama_am, area
         FROM master_user
        WHERE aktif = TRUE AND role = 'AM'
     ),
     v AS (
       SELECT user_id, COUNT(*)::int AS n
         FROM activity_log
        WHERE tanggal = $1::date
        GROUP BY user_id
     ),
     p AS (
       SELECT user_id, COUNT(*)::int AS n
         FROM sales_plan
        WHERE tanggal = $1::date
        GROUP BY user_id
     )
     SELECT am.user_id, am.nama_am, am.area,
            COALESCE(v.n, 0) AS visits,
            COALESCE(p.n, 0) AS plans
       FROM am
       LEFT JOIN v USING (user_id)
       LEFT JOIN p USING (user_id)`,
    [tanggal],
  );
  const amStats = amStatsRes.rows;

  const totalVisits = amStats.reduce((s, r) => s + r.visits, 0);
  const totalPlans = amStats.reduce((s, r) => s + r.plans, 0);
  const activeTeamCount = amStats.filter((r) => r.visits > 0).length;
  const coveragePct = totalPlans > 0 ? Math.round((totalVisits / totalPlans) * 100) : 0;

  // Top performers: AMs with ≥1 visit, sorted desc by visits.
  const sortedByVisits = amStats
    .filter((r) => r.visits > 0)
    .sort((a, b) => b.visits - a.visits);
  const topVisits = sortedByVisits[0]?.visits ?? 0;
  const topPerformers = sortedByVisits.filter((r) => r.visits === topVisits).slice(0, 3);

  // Need attention: AMs with plans hari ini tapi 0 visits (paling concern),
  // fallback ke AMs dengan 0 visits saja jika nobody has plans skipped.
  const planSkipped = amStats.filter((r) => r.plans > 0 && r.visits === 0);
  const needAttention = planSkipped.length > 0
    ? planSkipped.slice(0, 5)
    : amStats.filter((r) => r.visits === 0).slice(0, 5);

  // Hot deals: pipeline_tracker dengan status='Hot' yang updated hari ini,
  // OR yang baru naik stage hari ini (stage ≥ 3).
  const hotRes = await query<HotDealRow>(
    `SELECT pt.customer_name, mu.nama_am, pt.stage, pt.status, pt.note,
            to_char(pt.updated_at, 'YYYY-MM-DD HH24:MI') AS updated_at
       FROM pipeline_tracker pt
       JOIN master_user mu ON mu.id = pt.user_id
      WHERE pt.updated_at::date = $1::date
        AND (pt.status = 'Hot' OR pt.stage >= 3)
      ORDER BY pt.stage DESC, pt.updated_at DESC
      LIMIT 5`,
    [tanggal],
  );

  return {
    tanggal,
    totalAmRoster,
    activeTeamCount,
    totalVisits,
    totalPlans,
    coveragePct,
    hotDeals: hotRes.rows,
    needAttention,
    topPerformers,
    amStats,
  };
}
