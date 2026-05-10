import { query } from '../db.js';
import { fetchSummary, type SummaryData } from '../summary/queries.js';
import { getResendStats } from '../repo/resend.js';
import { todayWib } from '../util/dateid.js';

export interface AmActivityRow {
  user_id: number;
  nama_am: string;
  area: string | null;
  visits: number;
  plans: number;
  last_activity_at: string | null;
}

export interface RecentActivityRow {
  id: number;
  customer_name: string;
  tanggal: string;
  hasil: string | null;
  next_action: string | null;
  nama_am: string;
  area: string | null;
  created_at: string;
}

export interface StageRow {
  stage: number;
  status: string;
  count: number;
}

export interface TopDealRow {
  id: number;
  customer_name: string;
  nama_am: string;
  area: string | null;
  produk: string | null;
  stage: number;
  status: string;
  nilai_deal: string | null;
  updated_at: string;
}

export interface RateLimitedRow {
  wa_number: string;
  count: number;
  last_hit: string;
}

export interface FailedDeliveryRow {
  id: number;
  source: string;
  to_kind: string;
  target: string;
  text_preview: string | null;
  resend_count: number;
  attempts: number;
  error: string | null;
  created_at: string;
}

export async function fetchOverview(): Promise<{
  summary: SummaryData;
  amStats: AmActivityRow[];
}> {
  const tanggal = todayWib();
  const summary = await fetchSummary(tanggal);

  const amStats = await query<AmActivityRow>(
    `WITH am AS (
       SELECT id AS user_id, nama_am, area FROM master_user
        WHERE aktif = TRUE AND role = 'AM'
     ),
     v AS (
       SELECT user_id,
              COUNT(*)::int AS n,
              to_char(MAX(created_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS last_at
         FROM activity_log
        WHERE tanggal = $1::date
        GROUP BY user_id
     ),
     p AS (
       SELECT user_id, COUNT(*)::int AS n FROM sales_plan
        WHERE tanggal = $1::date
        GROUP BY user_id
     )
     SELECT am.user_id, am.nama_am, am.area,
            COALESCE(v.n, 0) AS visits,
            COALESCE(p.n, 0) AS plans,
            v.last_at AS last_activity_at
       FROM am
       LEFT JOIN v USING (user_id)
       LEFT JOIN p USING (user_id)
       ORDER BY visits DESC, plans DESC, am.nama_am ASC`,
    [tanggal],
  );

  return { summary, amStats: amStats.rows };
}

export async function fetchRecentActivity(limit = 30): Promise<RecentActivityRow[]> {
  const r = await query<RecentActivityRow>(
    `SELECT al.id, al.customer_name, al.tanggal,
            al.hasil, al.next_action,
            mu.nama_am, mu.area,
            to_char(al.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS created_at
       FROM activity_log al
       JOIN master_user mu ON mu.id = al.user_id
      ORDER BY al.created_at DESC
      LIMIT $1`,
    [Math.min(Math.max(limit, 1), 200)],
  );
  return r.rows;
}

export async function fetchPipelineSnapshot(): Promise<{
  stageBreakdown: StageRow[];
  topDeals: TopDealRow[];
  byStatus: Array<{ status: string; count: number }>;
}> {
  const stage = await query<StageRow>(
    `SELECT stage, status, COUNT(*)::int AS count
       FROM pipeline_tracker
      GROUP BY stage, status
      ORDER BY stage, status`,
  );
  const byStatus = await query<{ status: string; count: number }>(
    `SELECT status, COUNT(*)::int AS count
       FROM pipeline_tracker
      GROUP BY status
      ORDER BY count DESC`,
  );
  const top = await query<TopDealRow>(
    `SELECT pt.id, pt.customer_name, mu.nama_am, mu.area, pt.produk,
            pt.stage, pt.status, pt.nilai_deal::text AS nilai_deal,
            to_char(pt.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS updated_at
       FROM pipeline_tracker pt
       JOIN master_user mu ON mu.id = pt.user_id
      WHERE pt.status IN ('Hot', 'Won') OR pt.stage >= 3
      ORDER BY pt.stage DESC, pt.updated_at DESC
      LIMIT 15`,
  );
  return { stageBreakdown: stage.rows, topDeals: top.rows, byStatus: byStatus.rows };
}

export async function fetchOps(): Promise<{
  resend: { pending: number; resolved24h: number; exhausted: number };
  rateLimitedRecent: RateLimitedRow[];
  failedDeliveries: FailedDeliveryRow[];
  auditSummary: Array<{ status: string; count: number }>;
}> {
  const resend = await getResendStats();

  const rl = await query<RateLimitedRow>(
    `SELECT wa_number,
            COUNT(*)::int AS count,
            to_char(MAX(created_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS last_hit
       FROM audit_log
      WHERE status = 'RATE_LIMITED'
        AND created_at > NOW() - INTERVAL '1 hour'
      GROUP BY wa_number
      ORDER BY count DESC
      LIMIT 10`,
  );

  const failed = await query<FailedDeliveryRow>(
    `SELECT id, source, to_kind, target, text_preview, resend_count, attempts, error,
            to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SSZ') AS created_at
       FROM delivery_log
      WHERE delivered = FALSE AND resolved = FALSE
      ORDER BY created_at DESC
      LIMIT 20`,
  );

  const audit = await query<{ status: string; count: number }>(
    `SELECT status, COUNT(*)::int AS count
       FROM audit_log
      WHERE created_at > NOW() - INTERVAL '24 hours'
      GROUP BY status
      ORDER BY count DESC`,
  );

  return {
    resend,
    rateLimitedRecent: rl.rows,
    failedDeliveries: failed.rows,
    auditSummary: audit.rows,
  };
}
