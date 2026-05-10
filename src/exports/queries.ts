import { query } from '../db.js';

export interface DateRange {
  from?: string; // YYYY-MM-DD
  to?: string;   // YYYY-MM-DD
}

export interface PipelineExportRow {
  id: number;
  customer_name: string;
  nama_am: string;
  area: string | null;
  produk: string | null;
  nilai_deal: string | null;
  stage: number;
  status: string;
  note: string | null;
  created_at: string;
  updated_at: string;
}

export async function exportPipeline(): Promise<PipelineExportRow[]> {
  const r = await query<PipelineExportRow>(
    `SELECT pt.id, pt.customer_name, mu.nama_am, mu.area, pt.produk,
            pt.nilai_deal::text AS nilai_deal,
            pt.stage, pt.status, pt.note,
            to_char(pt.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS created_at,
            to_char(pt.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS updated_at
       FROM pipeline_tracker pt
       JOIN master_user mu ON mu.id = pt.user_id
      ORDER BY pt.stage DESC, pt.updated_at DESC`,
  );
  return r.rows;
}

export interface ActivityExportRow {
  id: number;
  tanggal: string;
  nama_am: string;
  area: string | null;
  customer_name: string;
  tujuan: string | null;
  hasil: string | null;
  next_action: string | null;
  source: string | null;
  pipeline_id: number | null;
  created_at: string;
}

export async function exportActivity(range: DateRange): Promise<ActivityExportRow[]> {
  const conds: string[] = [];
  const params: unknown[] = [];
  if (range.from) {
    params.push(range.from);
    conds.push(`al.tanggal >= $${params.length}::date`);
  }
  if (range.to) {
    params.push(range.to);
    conds.push(`al.tanggal <= $${params.length}::date`);
  }
  const where = conds.length ? `WHERE ${conds.join(' AND ')}` : '';
  const r = await query<ActivityExportRow>(
    `SELECT al.id,
            to_char(al.tanggal, 'YYYY-MM-DD') AS tanggal,
            mu.nama_am, mu.area,
            al.customer_name, al.tujuan, al.hasil, al.next_action,
            al.source, al.pipeline_id,
            to_char(al.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS created_at
       FROM activity_log al
       JOIN master_user mu ON mu.id = al.user_id
       ${where}
      ORDER BY al.tanggal DESC, mu.nama_am, al.id`,
    params,
  );
  return r.rows;
}

export interface PlanExportRow {
  id: number;
  tanggal: string;
  nama_am: string;
  area: string | null;
  customer_name: string;
  tujuan: string | null;
  goal: string | null;
  seq: number;
  created_at: string;
}

export async function exportPlans(range: DateRange): Promise<PlanExportRow[]> {
  const conds: string[] = [];
  const params: unknown[] = [];
  if (range.from) {
    params.push(range.from);
    conds.push(`sp.tanggal >= $${params.length}::date`);
  }
  if (range.to) {
    params.push(range.to);
    conds.push(`sp.tanggal <= $${params.length}::date`);
  }
  const where = conds.length ? `WHERE ${conds.join(' AND ')}` : '';
  const r = await query<PlanExportRow>(
    `SELECT sp.id,
            to_char(sp.tanggal, 'YYYY-MM-DD') AS tanggal,
            mu.nama_am, mu.area,
            sp.customer_name, sp.tujuan, sp.goal, sp.seq,
            to_char(sp.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') AS created_at
       FROM sales_plan sp
       JOIN master_user mu ON mu.id = sp.user_id
       ${where}
      ORDER BY sp.tanggal DESC, mu.nama_am, sp.seq`,
    params,
  );
  return r.rows;
}

export interface DealsExportRow {
  id: number;
  tanggal_closed: string;
  nama_am: string;
  area: string | null;
  customer_name: string;
  produk: string | null;
  nilai_deal: string | null;
  catatan: string | null;
}

export async function exportDeals(range: DateRange): Promise<DealsExportRow[]> {
  const conds: string[] = [];
  const params: unknown[] = [];
  if (range.from) {
    params.push(range.from);
    conds.push(`dc.tanggal_closed >= $${params.length}::date`);
  }
  if (range.to) {
    params.push(range.to);
    conds.push(`dc.tanggal_closed <= $${params.length}::date`);
  }
  const where = conds.length ? `WHERE ${conds.join(' AND ')}` : '';
  const r = await query<DealsExportRow>(
    `SELECT dc.id,
            to_char(dc.tanggal_closed, 'YYYY-MM-DD') AS tanggal_closed,
            mu.nama_am, mu.area,
            dc.customer_name, dc.produk,
            dc.nilai_deal::text AS nilai_deal,
            dc.catatan
       FROM deal_closed dc
       JOIN master_user mu ON mu.id = dc.user_id
       ${where}
      ORDER BY dc.tanggal_closed DESC`,
    params,
  );
  return r.rows;
}
