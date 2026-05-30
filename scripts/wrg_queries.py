"""WRG CRM — SQL query constants.

All queries return json_agg() — single JSON blob for simple parsing.
Date range placeholders {d1}/{d2} must be regex-validated by caller before
.format() substitution (psql_quote-style escaping not applied since dates
are validated separately).

Constants:
- SQL_SUMMARY           — KPI strip data (per range)
- _PER_ORANG_CTE        — base CTE for per-orang/divisi/cabang
- SQL_PER_ORANG         — per-user breakdown
- SQL_PER_DIVISI        — per-role aggregation
- SQL_PER_CABANG        — per-branch aggregation
- SQL_PER_HOD           — per-HOD sales aggregation (AM only)
- SQL_DAILY_TREND       — day-by-day stats for tren chart
- SQL_DRILLDOWN_USER    — single user detail (plans/todos/unmatched activity)
"""

SQL_SUMMARY = """
WITH params AS (SELECT DATE '{d1}' AS d1, DATE '{d2}' AS d2),
working_days AS (
  SELECT COUNT(*) AS n
  FROM generate_series((SELECT d1 FROM params), (SELECT d2 FROM params), '1 day') g
  WHERE is_working_day(g::date)
),
plan_stats AS (
  SELECT
    COUNT(*) AS total_plan_visits,
    COUNT(*) FILTER (WHERE reported)     AS plan_reported,
    COUNT(*) FILTER (WHERE is_late_plan) AS plan_late,
    COUNT(DISTINCT user_id)              AS users_with_plan
  FROM sales_plan sp, params p
  WHERE sp.tanggal BETWEEN p.d1 AND p.d2
),
todo_stats AS (
  SELECT
    COUNT(*)                              AS total_todos,
    COALESCE(SUM(total_items), 0)         AS total_todo_items,
    COUNT(*) FILTER (WHERE reported)      AS todo_reported,
    COUNT(*) FILTER (WHERE is_late_plan)  AS todo_late,
    COUNT(DISTINCT user_id)               AS users_with_todo
  FROM sales_todo st, params p
  WHERE st.tanggal BETWEEN p.d1 AND p.d2
),
activity_stats AS (
  SELECT
    COUNT(*)                                AS total_activity,
    COUNT(*) FILTER (WHERE is_unmatched)    AS unmatched_activity,
    COUNT(*) FILTER (WHERE NOT is_unmatched) AS matched_activity,
    -- users_with_report: union activity_log (AM mode) + sales_todo.reported (TODO mode)
    (SELECT COUNT(DISTINCT user_id) FROM (
       SELECT user_id FROM activity_log, params p2
       WHERE tanggal BETWEEN p2.d1 AND p2.d2
       UNION
       SELECT user_id FROM sales_todo, params p3
       WHERE tanggal BETWEEN p3.d1 AND p3.d2 AND reported
    ) u)                                    AS users_with_report
  FROM activity_log al, params p
  WHERE al.tanggal BETWEEN p.d1 AND p.d2
),
todo_report_stats AS (
  -- Aggregate matched/unmatched dari sales_todo.report_data jsonb (TODO mode).
  SELECT
    COALESCE(SUM(
      (SELECT COUNT(*) FROM jsonb_array_elements(COALESCE(report_data, '[]'::jsonb)) AS r
       WHERE r->>'status' = 'matched')
    ), 0) AS todo_items_matched,
    COALESCE(SUM(
      (SELECT COUNT(*) FROM jsonb_array_elements(COALESCE(report_data, '[]'::jsonb)) AS r
       WHERE r->>'status' IN ('ambiguous','unmatched'))
    ), 0) AS todo_items_unmatched
  FROM sales_todo, params p
  WHERE tanggal BETWEEN p.d1 AND p.d2
),
user_counts AS (
  SELECT
    COUNT(*) FILTER (WHERE aktif AND wajib_plan_report) AS users_wajib,
    COUNT(*) FILTER (WHERE aktif)                       AS users_aktif
  FROM master_user
)
SELECT row_to_json(t) FROM (
  SELECT
    (SELECT n FROM working_days)               AS working_days,
    (SELECT total_plan_visits FROM plan_stats) AS total_plan_visits,
    (SELECT plan_reported FROM plan_stats)     AS plan_reported,
    (SELECT plan_late FROM plan_stats)         AS plan_late,
    (SELECT users_with_plan FROM plan_stats)   AS users_with_plan,
    (SELECT total_todos FROM todo_stats)       AS total_todos,
    (SELECT total_todo_items FROM todo_stats)  AS total_todo_items,
    (SELECT todo_reported FROM todo_stats)     AS todo_reported,
    (SELECT todo_late FROM todo_stats)         AS todo_late,
    (SELECT users_with_todo FROM todo_stats)   AS users_with_todo,
    (SELECT total_activity FROM activity_stats)    AS total_activity,
    (SELECT unmatched_activity FROM activity_stats) AS unmatched_activity,
    (SELECT matched_activity FROM activity_stats)  AS matched_activity,
    (SELECT users_with_report FROM activity_stats) AS users_with_report,
    (SELECT todo_items_matched FROM todo_report_stats)    AS todo_items_matched,
    (SELECT todo_items_unmatched FROM todo_report_stats)  AS todo_items_unmatched,
    (SELECT users_wajib FROM user_counts)      AS users_wajib,
    (SELECT users_aktif FROM user_counts)      AS users_aktif
) t;
"""


# Per-orang base CTE used in several queries (per-orang, per-divisi, per-cabang).
_PER_ORANG_CTE = """
WITH params AS (SELECT DATE '{d1}' AS d1, DATE '{d2}' AS d2),
per_orang AS (
  SELECT
    mu.id          AS user_id,
    mu.nama,
    mu.panggilan,
    mu.role,
    mu.posisi,
    mu.cabang,
    mu.wa_number,
    mu.last_active_group,
    mu.last_active_at,
    COALESCE(sp.total_plan_visits, 0)      AS total_plan_visits,
    COALESCE(sp.plan_reported, 0)          AS plan_reported,
    COALESCE(sp.plan_late, 0)              AS plan_late,
    COALESCE(st.total_todos, 0)            AS total_todos,
    COALESCE(st.total_todo_items, 0)       AS total_todo_items,
    COALESCE(st.todo_reported, 0)          AS todo_reported,
    COALESCE(st.todo_late, 0)              AS todo_late,
    COALESCE(st.todo_items_matched, 0)     AS todo_items_matched,
    COALESCE(st.todo_items_unmatched, 0)   AS todo_items_unmatched,
    COALESCE(act.total_activity, 0)        AS total_activity,
    COALESCE(act.matched_activity, 0)      AS matched_activity,
    COALESCE(act.unmatched_activity, 0)    AS unmatched_activity,
    COALESCE(d.active_days, 0)             AS active_days,
    is_on_leave(mu.id, CURRENT_DATE)       AS on_leave_today,
    (SELECT jenis FROM v_leave_today WHERE user_id = mu.id LIMIT 1) AS leave_jenis_today
  FROM master_user mu
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*)                              AS total_plan_visits,
      COUNT(*) FILTER (WHERE reported)      AS plan_reported,
      COUNT(*) FILTER (WHERE is_late_plan)  AS plan_late
    FROM sales_plan, params
    WHERE user_id = mu.id AND tanggal BETWEEN params.d1 AND params.d2
  ) sp ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*)                              AS total_todos,
      COALESCE(SUM(total_items), 0)         AS total_todo_items,
      COUNT(*) FILTER (WHERE reported)      AS todo_reported,
      COUNT(*) FILTER (WHERE is_late_plan)  AS todo_late,
      COALESCE(SUM(
        (SELECT COUNT(*) FROM jsonb_array_elements(COALESCE(report_data, '[]'::jsonb)) AS r
         WHERE r->>'status' = 'matched')
      ), 0)                                  AS todo_items_matched,
      COALESCE(SUM(
        (SELECT COUNT(*) FROM jsonb_array_elements(COALESCE(report_data, '[]'::jsonb)) AS r
         WHERE r->>'status' IN ('ambiguous','unmatched'))
      ), 0)                                  AS todo_items_unmatched
    FROM sales_todo, params
    WHERE user_id = mu.id AND tanggal BETWEEN params.d1 AND params.d2
  ) st ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*)                                  AS total_activity,
      COUNT(*) FILTER (WHERE is_unmatched)      AS unmatched_activity,
      COUNT(*) FILTER (WHERE NOT is_unmatched)  AS matched_activity
    FROM activity_log, params
    WHERE user_id = mu.id AND tanggal BETWEEN params.d1 AND params.d2
  ) act ON TRUE
  LEFT JOIN LATERAL (
    SELECT COUNT(DISTINCT tanggal) AS active_days
    FROM (
      SELECT tanggal FROM sales_plan, params
        WHERE user_id = mu.id AND tanggal BETWEEN params.d1 AND params.d2
      UNION
      SELECT tanggal FROM sales_todo, params
        WHERE user_id = mu.id AND tanggal BETWEEN params.d1 AND params.d2
      UNION
      SELECT tanggal FROM activity_log, params
        WHERE user_id = mu.id AND tanggal BETWEEN params.d1 AND params.d2
    ) days
  ) d ON TRUE
  WHERE mu.aktif AND mu.wajib_plan_report
)
"""


SQL_PER_ORANG = _PER_ORANG_CTE + """
SELECT COALESCE(json_agg(row_to_json(per_orang) ORDER BY role, panggilan), '[]'::json)
FROM per_orang;
"""


SQL_PER_DIVISI = _PER_ORANG_CTE + """
SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.role), '[]'::json) FROM (
  SELECT
    role,
    COUNT(*)                                              AS jumlah_orang,
    SUM(total_plan_visits + total_todo_items)             AS total_plan,
    SUM(plan_reported)                                    AS plan_reported,
    SUM(todo_reported)                                    AS todo_reported,
    SUM(todo_items_matched)                               AS todo_items_matched,
    SUM(todo_items_unmatched)                             AS todo_items_unmatched,
    SUM(total_activity)                                   AS total_activity,
    SUM(matched_activity)                                 AS matched_activity,
    SUM(unmatched_activity)                               AS unmatched_activity,
    SUM(plan_late + todo_late)                            AS total_late,
    COUNT(*) FILTER (WHERE total_plan_visits + total_todos > 0) AS orang_dgn_plan,
    COUNT(*) FILTER (WHERE total_activity > 0 OR todo_reported > 0) AS orang_dgn_report
  FROM per_orang
  GROUP BY role
) t;
"""


SQL_PER_CABANG = _PER_ORANG_CTE + """
SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.cabang), '[]'::json) FROM (
  SELECT
    cabang,
    COUNT(*)                                              AS jumlah_orang,
    SUM(total_plan_visits + total_todo_items)             AS total_plan,
    SUM(plan_reported)                                    AS plan_reported,
    SUM(todo_reported)                                    AS todo_reported,
    SUM(todo_items_matched)                               AS todo_items_matched,
    SUM(todo_items_unmatched)                             AS todo_items_unmatched,
    SUM(total_activity)                                   AS total_activity,
    SUM(matched_activity)                                 AS matched_activity,
    SUM(unmatched_activity)                               AS unmatched_activity,
    SUM(plan_late + todo_late)                            AS total_late,
    COUNT(*) FILTER (WHERE total_plan_visits + total_todos > 0) AS orang_dgn_plan,
    COUNT(*) FILTER (WHERE total_activity > 0 OR todo_reported > 0) AS orang_dgn_report,
    STRING_AGG(DISTINCT role, ', ' ORDER BY role)         AS roles
  FROM per_orang
  GROUP BY cabang
) t;
"""


SQL_PER_HOD = """
WITH params AS (SELECT DATE '{d1}' AS d1, DATE '{d2}' AS d2),
am_user AS (
  SELECT
    mu.id, mu.nama, mu.panggilan, mu.cabang,
    UPPER(mu.panggilan) AS panggilan_uc
  FROM master_user mu
  WHERE mu.role = 'AM' AND mu.aktif AND mu.wajib_plan_report
),
am_hod AS (
  SELECT DISTINCT au.id, au.nama, au.panggilan, au.cabang,
                  t.hod_panggilan
  FROM am_user au
  LEFT JOIN master_territory t ON t.am_panggilan = au.panggilan_uc
),
hod_user AS (
  SELECT id, nama, panggilan, cabang,
         COALESCE(hod_panggilan, '— (tanpa territory)') AS hod_panggilan
  FROM am_hod
),
am_stats AS (
  SELECT
    hu.hod_panggilan,
    COUNT(DISTINCT hu.id)                            AS jumlah_am,
    COALESCE(SUM(sp.total_plan), 0)                  AS total_plan_visits,
    COALESCE(SUM(sp.reported), 0)                    AS plan_reported,
    COALESCE(SUM(sp.late), 0)                        AS plan_late,
    COALESCE(SUM(act.total_activity), 0)             AS total_activity,
    COALESCE(SUM(act.matched), 0)                    AS matched_activity,
    COALESCE(SUM(act.unmatched), 0)                  AS unmatched_activity,
    COUNT(DISTINCT hu.id) FILTER (
      WHERE COALESCE(sp.total_plan, 0) > 0
    )                                                AS am_dgn_plan,
    COUNT(DISTINCT hu.id) FILTER (
      WHERE COALESCE(act.total_activity, 0) > 0
    )                                                AS am_dgn_report
  FROM hod_user hu
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*) AS total_plan,
      COUNT(*) FILTER (WHERE reported)     AS reported,
      COUNT(*) FILTER (WHERE is_late_plan) AS late
    FROM sales_plan, params
    WHERE user_id = hu.id AND tanggal BETWEEN params.d1 AND params.d2
  ) sp ON TRUE
  LEFT JOIN LATERAL (
    SELECT
      COUNT(*) AS total_activity,
      COUNT(*) FILTER (WHERE NOT is_unmatched) AS matched,
      COUNT(*) FILTER (WHERE is_unmatched)     AS unmatched
    FROM activity_log, params
    WHERE user_id = hu.id AND tanggal BETWEEN params.d1 AND params.d2
  ) act ON TRUE
  GROUP BY hu.hod_panggilan
),
hod_label AS (
  SELECT
    s.*,
    mu.nama AS hod_nama
  FROM am_stats s
  LEFT JOIN master_user mu
    ON UPPER(mu.panggilan) = s.hod_panggilan
   AND mu.role = 'HOD'
)
SELECT COALESCE(json_agg(row_to_json(hod_label) ORDER BY hod_panggilan), '[]'::json)
FROM hod_label;
"""


SQL_DAILY_TREND = """
WITH params AS (SELECT DATE '{d1}' AS d1, DATE '{d2}' AS d2),
days AS (
  SELECT generate_series(params.d1, params.d2, '1 day')::date AS d FROM params
)
SELECT COALESCE(json_agg(row_to_json(t) ORDER BY t.date), '[]'::json) FROM (
  SELECT
    d::text                                                                  AS date,
    EXTRACT(ISODOW FROM d)::int                                              AS isodow,
    is_working_day(d)                                                        AS is_working,
    (SELECT keterangan FROM master_holiday WHERE tanggal = d)                AS holiday,
    (SELECT COUNT(*)::int FROM sales_plan WHERE tanggal = d)                 AS plan_visits,
    (SELECT COUNT(*)::int FROM sales_plan WHERE tanggal = d AND is_late_plan) AS plan_late,
    (SELECT COUNT(*)::int FROM sales_plan WHERE tanggal = d AND reported)    AS plan_reported,
    (SELECT COUNT(*)::int FROM sales_todo WHERE tanggal = d)                 AS todo_count,
    (SELECT COALESCE(SUM(total_items),0)::int FROM sales_todo WHERE tanggal = d) AS todo_items,
    (SELECT COUNT(*)::int FROM sales_todo WHERE tanggal = d AND is_late_plan) AS todo_late,
    (SELECT COUNT(*)::int FROM sales_todo WHERE tanggal = d AND reported)    AS todo_reported,
    (SELECT COUNT(*)::int FROM activity_log WHERE tanggal = d)               AS total_activity,
    (SELECT COUNT(*)::int FROM activity_log WHERE tanggal = d AND is_unmatched) AS unmatched,
    (SELECT COUNT(DISTINCT user_id)::int FROM (
      SELECT user_id FROM sales_plan WHERE tanggal = d
      UNION SELECT user_id FROM sales_todo WHERE tanggal = d
    ) u)                                                                     AS users_submitted,
    (SELECT COUNT(DISTINCT user_id)::int FROM activity_log WHERE tanggal = d) AS users_reported
  FROM days
) t;
"""


SQL_DRILLDOWN_USER = """
WITH params AS (
  SELECT INT '{user_id}' AS uid, DATE '{d1}' AS d1, DATE '{d2}' AS d2
),
user_info AS (
  SELECT json_build_object(
    'id', mu.id,
    'nama', mu.nama,
    'panggilan', mu.panggilan,
    'role', mu.role,
    'posisi', mu.posisi,
    'cabang', mu.cabang,
    'wa_number', mu.wa_number,
    'last_active_group', mu.last_active_group,
    'last_active_at', mu.last_active_at
  ) AS info
  FROM master_user mu, params
  WHERE mu.id = params.uid
),
plan_rows AS (
  SELECT json_agg(row_to_json(t) ORDER BY t.tanggal DESC, t.seq) AS rows FROM (
    SELECT
      sp.id, sp.tanggal, sp.seq,
      sp.customer_name, sp.tujuan, sp.goal,
      sp.reported, sp.reported_at,
      sp.is_late_plan, sp.submitted_at,
      sp.activity_id,
      sp.visit_lat, sp.visit_lon, sp.visit_timestamp, sp.visit_date_mismatch,
      al.hasil, al.next_action, al.match_score
    FROM sales_plan sp
    CROSS JOIN params
    LEFT JOIN activity_log al ON al.id = sp.activity_id
    WHERE sp.user_id = params.uid
      AND sp.tanggal BETWEEN params.d1 AND params.d2
  ) t
),
todo_rows AS (
  SELECT json_agg(row_to_json(t) ORDER BY t.tanggal DESC, t.id) AS rows FROM (
    SELECT
      st.id, st.tanggal, st.items, st.total_items,
      st.reported, st.reported_at,
      st.is_late_plan, st.submitted_at,
      st.report_data
    FROM sales_todo st, params
    WHERE st.user_id = params.uid
      AND st.tanggal BETWEEN params.d1 AND params.d2
  ) t
),
unmatched_rows AS (
  SELECT json_agg(row_to_json(t) ORDER BY t.tanggal DESC, t.id) AS rows FROM (
    SELECT
      al.id, al.tanggal, al.customer_name,
      al.hasil, al.next_action, al.match_score, al.is_unmatched,
      al.created_at
    FROM activity_log al, params
    WHERE al.user_id = params.uid
      AND al.tanggal BETWEEN params.d1 AND params.d2
      AND al.plan_id IS NULL
  ) t
)
SELECT row_to_json(d) FROM (
  SELECT
    (SELECT info FROM user_info)               AS user,
    COALESCE((SELECT rows FROM plan_rows), '[]'::json)      AS plan,
    COALESCE((SELECT rows FROM todo_rows), '[]'::json)      AS todo,
    COALESCE((SELECT rows FROM unmatched_rows), '[]'::json) AS unmatched_activity
) d;
"""
