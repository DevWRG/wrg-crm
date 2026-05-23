-- ============================================================
-- WRG CRM — Initial Schema (consolidated DDL — 2026-05-23 snapshot)
-- ============================================================
-- Generated from live wrg_crm_dev via pg_dump --schema-only.
-- Includes ALL tables, indexes, functions, views, and extensions
-- already in their final post-migration shape.
--
-- ⚠️  For FRESH installs, apply ONLY:
--   psql -U wrg_admin -d wrg_crm_dev -f schema/00_initial.sql
--   psql -U wrg_admin -d wrg_crm_dev -f schema/master_data_seed.sql
--
-- The other schema/*.sql files (schema_update_v2.sql, sales_todo_v1.sql)
-- are HISTORICAL migrations that have already been incorporated here.
-- They are kept for reference / audit only; running them on a fresh DB
-- created from this file will fail (e.g. trying to rename a column that
-- no longer exists).
-- ============================================================

--
-- PostgreSQL database dump
--


-- Dumped from database version 16.13 (Homebrew)
-- Dumped by pg_dump version 16.13 (Homebrew)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: is_working_day(date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_working_day(check_date date DEFAULT CURRENT_DATE) RETURNS boolean
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Sabtu = 6, Minggu = 0
  IF EXTRACT(DOW FROM check_date) IN (0, 6) THEN
    RETURN FALSE;
  END IF;
  -- Cek libur nasional
  IF EXISTS (SELECT 1 FROM master_holiday WHERE tanggal = check_date) THEN
    RETURN FALSE;
  END IF;
  RETURN TRUE;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: activity_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_log (
    id integer NOT NULL,
    user_id integer NOT NULL,
    pipeline_id integer,
    customer_name text NOT NULL,
    tanggal date NOT NULL,
    tujuan text,
    hasil text,
    next_action text,
    source text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    plan_id integer,
    is_unmatched boolean DEFAULT false,
    match_score numeric(4,3),
    todo_id integer,
    todo_item_idx integer,
    message_id text
);


--
-- Name: activity_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.activity_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: activity_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.activity_log_id_seq OWNED BY public.activity_log.id;


--
-- Name: alert_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.alert_log (
    id integer NOT NULL,
    kind text NOT NULL,
    level text NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    payload jsonb DEFAULT '{}'::jsonb NOT NULL,
    channels_delivered jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    escalation_for integer,
    escalated_at timestamp with time zone
);


--
-- Name: alert_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.alert_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: alert_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.alert_log_id_seq OWNED BY public.alert_log.id;


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    id integer NOT NULL,
    wa_number text,
    nama_am text,
    hashtag text NOT NULL,
    status text NOT NULL,
    customer_count integer DEFAULT 0 NOT NULL,
    payload jsonb,
    error_detail text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: audit_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.audit_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: audit_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.audit_log_id_seq OWNED BY public.audit_log.id;


--
-- Name: auth_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_log (
    id integer NOT NULL,
    email text,
    event text NOT NULL,
    reason text,
    ip text,
    user_agent text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: auth_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.auth_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: auth_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.auth_log_id_seq OWNED BY public.auth_log.id;


--
-- Name: master_user; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.master_user (
    id integer NOT NULL,
    wa_number text NOT NULL,
    nama text NOT NULL,
    area text,
    role text DEFAULT 'AM'::text NOT NULL,
    aktif boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_active_group character varying(100),
    last_active_at timestamp without time zone,
    panggilan character varying(50),
    posisi character varying(100),
    cabang character varying(50),
    wajib_plan_report boolean DEFAULT true
);


--
-- Name: sales_plan; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sales_plan (
    id integer NOT NULL,
    user_id integer NOT NULL,
    tanggal date NOT NULL,
    customer_name text NOT NULL,
    tujuan text,
    goal text,
    seq integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    reported boolean DEFAULT false,
    reported_at timestamp without time zone,
    activity_id integer,
    is_late_plan boolean DEFAULT false,
    submitted_at timestamp without time zone DEFAULT now()
);


--
-- Name: daily_plan_report_status; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.daily_plan_report_status AS
 SELECT mu.id AS user_id,
    mu.wa_number,
    mu.nama,
    mu.area,
    mu.role,
    mu.last_active_group,
    sp.tanggal,
    count(sp.id) AS total_plan,
    count(sp.id) FILTER (WHERE (sp.reported = true)) AS total_reported,
    count(sp.id) FILTER (WHERE (sp.reported = false)) AS total_unreported,
    array_agg(sp.customer_name ORDER BY sp.seq) FILTER (WHERE (sp.reported = false)) AS unreported_customers,
    min(sp.submitted_at) AS first_plan_at,
    max(sp.submitted_at) AS last_plan_at,
    bool_or(sp.is_late_plan) AS has_late_plan
   FROM (public.master_user mu
     LEFT JOIN public.sales_plan sp ON (((sp.user_id = mu.id) AND (sp.tanggal = CURRENT_DATE))))
  WHERE (mu.aktif = true)
  GROUP BY mu.id, mu.wa_number, mu.nama, mu.area, mu.role, mu.last_active_group, sp.tanggal;


--
-- Name: sales_todo; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sales_todo (
    id integer NOT NULL,
    user_id integer NOT NULL,
    tanggal date NOT NULL,
    items jsonb NOT NULL,
    total_items integer GENERATED ALWAYS AS (jsonb_array_length(items)) STORED,
    raw_body text,
    message_id text,
    submitted_at timestamp without time zone DEFAULT now(),
    is_late_plan boolean DEFAULT false,
    reported boolean DEFAULT false,
    reported_at timestamp without time zone,
    created_at timestamp without time zone DEFAULT now(),
    report_data jsonb,
    report_msg_id text
);


--
-- Name: daily_plan_status_all; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.daily_plan_status_all AS
 SELECT mu.id AS user_id,
    mu.wa_number,
    mu.nama,
    mu.panggilan,
    mu.role,
    mu.cabang,
    mu.last_active_group,
    CURRENT_DATE AS tanggal,
    COALESCE(sp_stats.total_plan, (0)::bigint) AS total_plan,
    COALESCE(sp_stats.total_unreported, (0)::bigint) AS total_unreported,
    sp_stats.unreported_customers,
    COALESCE(st_stats.total_todo, (0)::bigint) AS total_todo,
    COALESCE(st_stats.total_items, (0)::bigint) AS total_todo_items,
    COALESCE(sp_stats.first_plan_at, st_stats.first_todo_at) AS first_submit_at,
    COALESCE(sp_stats.last_plan_at, st_stats.last_todo_at) AS last_submit_at,
    ((COALESCE(sp_stats.total_plan, (0)::bigint) > 0) OR (COALESCE(st_stats.total_todo, (0)::bigint) > 0)) AS has_submission,
    COALESCE(sp_stats.has_late, st_stats.has_late, false) AS has_late_plan
   FROM ((public.master_user mu
     LEFT JOIN LATERAL ( SELECT count(*) AS total_plan,
            count(*) FILTER (WHERE (sales_plan.reported = false)) AS total_unreported,
            array_agg(sales_plan.customer_name ORDER BY sales_plan.seq) FILTER (WHERE (sales_plan.reported = false)) AS unreported_customers,
            min(sales_plan.submitted_at) AS first_plan_at,
            max(sales_plan.submitted_at) AS last_plan_at,
            bool_or(sales_plan.is_late_plan) AS has_late
           FROM public.sales_plan
          WHERE ((sales_plan.user_id = mu.id) AND (sales_plan.tanggal = CURRENT_DATE))) sp_stats ON (true))
     LEFT JOIN LATERAL ( SELECT count(*) AS total_todo,
            sum(sales_todo.total_items) AS total_items,
            min(sales_todo.submitted_at) AS first_todo_at,
            max(sales_todo.submitted_at) AS last_todo_at,
            bool_or(sales_todo.is_late_plan) AS has_late
           FROM public.sales_todo
          WHERE ((sales_todo.user_id = mu.id) AND (sales_todo.tanggal = CURRENT_DATE))) st_stats ON (true))
  WHERE (mu.aktif = true);


--
-- Name: deal_closed; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.deal_closed (
    id integer NOT NULL,
    pipeline_id integer,
    user_id integer NOT NULL,
    customer_name text NOT NULL,
    nilai_deal numeric(15,2),
    produk text,
    tanggal_closed date NOT NULL,
    catatan text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: deal_closed_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.deal_closed_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: deal_closed_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.deal_closed_id_seq OWNED BY public.deal_closed.id;


--
-- Name: delivery_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.delivery_log (
    id integer NOT NULL,
    audit_id integer,
    source text NOT NULL,
    message_id_in text,
    wa_number text,
    to_kind text NOT NULL,
    target text NOT NULL,
    text_preview text,
    delivered boolean NOT NULL,
    attempts integer DEFAULT 1 NOT NULL,
    message_id_out text,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    text_full text,
    resend_count integer DEFAULT 0 NOT NULL,
    last_resend_at timestamp with time zone,
    resolved boolean DEFAULT false NOT NULL,
    parent_delivery_id integer
);


--
-- Name: delivery_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.delivery_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: delivery_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.delivery_log_id_seq OWNED BY public.delivery_log.id;


--
-- Name: email_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_log (
    id integer NOT NULL,
    kind text NOT NULL,
    recipients jsonb NOT NULL,
    subject text NOT NULL,
    range_from date,
    range_to date,
    delivered boolean NOT NULL,
    message_id text,
    error text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: email_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.email_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: email_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.email_log_id_seq OWNED BY public.email_log.id;


--
-- Name: master_holiday; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.master_holiday (
    id integer NOT NULL,
    tanggal date NOT NULL,
    keterangan character varying(100) NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


--
-- Name: master_holiday_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.master_holiday_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: master_holiday_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.master_holiday_id_seq OWNED BY public.master_holiday.id;


--
-- Name: master_territory; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.master_territory (
    id integer NOT NULL,
    am_panggilan character varying(20) NOT NULL,
    hod_panggilan character varying(20) NOT NULL,
    cabang character varying(50) NOT NULL,
    kota character varying(100) NOT NULL,
    created_at timestamp without time zone DEFAULT now()
);


--
-- Name: master_territory_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.master_territory_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: master_territory_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.master_territory_id_seq OWNED BY public.master_territory.id;


--
-- Name: master_user_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.master_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: master_user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.master_user_id_seq OWNED BY public.master_user.id;


--
-- Name: pending_confirm; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pending_confirm (
    id integer NOT NULL,
    wa_number text NOT NULL,
    hashtag text NOT NULL,
    candidates jsonb NOT NULL,
    payload jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '00:10:00'::interval) NOT NULL
);


--
-- Name: pending_confirm_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pending_confirm_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pending_confirm_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.pending_confirm_id_seq OWNED BY public.pending_confirm.id;


--
-- Name: pipeline_tracker; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pipeline_tracker (
    id integer NOT NULL,
    user_id integer NOT NULL,
    customer_name text NOT NULL,
    nama_am text,
    area text,
    produk text,
    nilai_deal numeric(15,2),
    stage integer DEFAULT 1 NOT NULL,
    status text DEFAULT 'Cold'::text NOT NULL,
    note text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT pipeline_tracker_stage_check CHECK (((stage >= 1) AND (stage <= 5))),
    CONSTRAINT pipeline_tracker_status_check CHECK ((status = ANY (ARRAY['Cold'::text, 'Warm'::text, 'Hot'::text, 'Won'::text, 'Lost'::text])))
);


--
-- Name: pipeline_tracker_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pipeline_tracker_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pipeline_tracker_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.pipeline_tracker_id_seq OWNED BY public.pipeline_tracker.id;


--
-- Name: processed_message; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.processed_message (
    message_id text NOT NULL,
    wa_number text NOT NULL,
    hashtag text,
    status text DEFAULT 'PROCESSING'::text NOT NULL,
    result_summary jsonb,
    processed_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    expires_at timestamp with time zone DEFAULT (now() + '7 days'::interval) NOT NULL
);


--
-- Name: sales_plan_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sales_plan_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sales_plan_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sales_plan_id_seq OWNED BY public.sales_plan.id;


--
-- Name: sales_todo_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.sales_todo_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sales_todo_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.sales_todo_id_seq OWNED BY public.sales_todo.id;


--
-- Name: user_session; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_session (
    token text NOT NULL,
    email text NOT NULL,
    name text,
    picture text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    expires_at timestamp with time zone DEFAULT (now() + '7 days'::interval) NOT NULL,
    ip text,
    user_agent text
);


--
-- Name: activity_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log ALTER COLUMN id SET DEFAULT nextval('public.activity_log_id_seq'::regclass);


--
-- Name: alert_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_log ALTER COLUMN id SET DEFAULT nextval('public.alert_log_id_seq'::regclass);


--
-- Name: audit_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log ALTER COLUMN id SET DEFAULT nextval('public.audit_log_id_seq'::regclass);


--
-- Name: auth_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_log ALTER COLUMN id SET DEFAULT nextval('public.auth_log_id_seq'::regclass);


--
-- Name: deal_closed id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deal_closed ALTER COLUMN id SET DEFAULT nextval('public.deal_closed_id_seq'::regclass);


--
-- Name: delivery_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_log ALTER COLUMN id SET DEFAULT nextval('public.delivery_log_id_seq'::regclass);


--
-- Name: email_log id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_log ALTER COLUMN id SET DEFAULT nextval('public.email_log_id_seq'::regclass);


--
-- Name: master_holiday id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.master_holiday ALTER COLUMN id SET DEFAULT nextval('public.master_holiday_id_seq'::regclass);


--
-- Name: master_territory id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.master_territory ALTER COLUMN id SET DEFAULT nextval('public.master_territory_id_seq'::regclass);


--
-- Name: master_user id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.master_user ALTER COLUMN id SET DEFAULT nextval('public.master_user_id_seq'::regclass);


--
-- Name: pending_confirm id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_confirm ALTER COLUMN id SET DEFAULT nextval('public.pending_confirm_id_seq'::regclass);


--
-- Name: pipeline_tracker id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_tracker ALTER COLUMN id SET DEFAULT nextval('public.pipeline_tracker_id_seq'::regclass);


--
-- Name: sales_plan id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_plan ALTER COLUMN id SET DEFAULT nextval('public.sales_plan_id_seq'::regclass);


--
-- Name: sales_todo id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_todo ALTER COLUMN id SET DEFAULT nextval('public.sales_todo_id_seq'::regclass);


--
-- Name: activity_log activity_log_message_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_message_id_key UNIQUE (message_id);


--
-- Name: activity_log activity_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_pkey PRIMARY KEY (id);


--
-- Name: alert_log alert_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_log
    ADD CONSTRAINT alert_log_pkey PRIMARY KEY (id);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (id);


--
-- Name: auth_log auth_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.auth_log
    ADD CONSTRAINT auth_log_pkey PRIMARY KEY (id);


--
-- Name: deal_closed deal_closed_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deal_closed
    ADD CONSTRAINT deal_closed_pkey PRIMARY KEY (id);


--
-- Name: delivery_log delivery_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_log
    ADD CONSTRAINT delivery_log_pkey PRIMARY KEY (id);


--
-- Name: email_log email_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_log
    ADD CONSTRAINT email_log_pkey PRIMARY KEY (id);


--
-- Name: master_holiday master_holiday_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.master_holiday
    ADD CONSTRAINT master_holiday_pkey PRIMARY KEY (id);


--
-- Name: master_holiday master_holiday_tanggal_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.master_holiday
    ADD CONSTRAINT master_holiday_tanggal_key UNIQUE (tanggal);


--
-- Name: master_territory master_territory_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.master_territory
    ADD CONSTRAINT master_territory_pkey PRIMARY KEY (id);


--
-- Name: master_user master_user_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.master_user
    ADD CONSTRAINT master_user_pkey PRIMARY KEY (id);


--
-- Name: master_user master_user_wa_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.master_user
    ADD CONSTRAINT master_user_wa_number_key UNIQUE (wa_number);


--
-- Name: pending_confirm pending_confirm_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_confirm
    ADD CONSTRAINT pending_confirm_pkey PRIMARY KEY (id);


--
-- Name: pipeline_tracker pipeline_tracker_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_tracker
    ADD CONSTRAINT pipeline_tracker_pkey PRIMARY KEY (id);


--
-- Name: processed_message processed_message_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_message
    ADD CONSTRAINT processed_message_pkey PRIMARY KEY (message_id);


--
-- Name: sales_plan sales_plan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_plan
    ADD CONSTRAINT sales_plan_pkey PRIMARY KEY (id);


--
-- Name: sales_plan sales_plan_user_id_tanggal_customer_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_plan
    ADD CONSTRAINT sales_plan_user_id_tanggal_customer_name_key UNIQUE (user_id, tanggal, customer_name);


--
-- Name: sales_todo sales_todo_message_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_todo
    ADD CONSTRAINT sales_todo_message_id_key UNIQUE (message_id);


--
-- Name: sales_todo sales_todo_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_todo
    ADD CONSTRAINT sales_todo_pkey PRIMARY KEY (id);


--
-- Name: sales_todo sales_todo_user_tgl_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_todo
    ADD CONSTRAINT sales_todo_user_tgl_unique UNIQUE (user_id, tanggal, message_id);


--
-- Name: user_session user_session_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_session
    ADD CONSTRAINT user_session_pkey PRIMARY KEY (token);


--
-- Name: idx_activity_msg; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_activity_msg ON public.activity_log USING btree (message_id);


--
-- Name: idx_activity_tanggal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_activity_tanggal ON public.activity_log USING btree (tanggal);


--
-- Name: idx_activity_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_activity_user ON public.activity_log USING btree (user_id);


--
-- Name: idx_alert_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_alert_created ON public.alert_log USING btree (created_at DESC);


--
-- Name: idx_alert_escalation_for; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_alert_escalation_for ON public.alert_log USING btree (escalation_for);


--
-- Name: idx_alert_kind_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_alert_kind_created ON public.alert_log USING btree (kind, created_at DESC);


--
-- Name: idx_alert_unescalated_warn; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_alert_unescalated_warn ON public.alert_log USING btree (created_at) WHERE ((kind = 'exhausted_resend'::text) AND (escalated_at IS NULL));


--
-- Name: idx_audit_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_created ON public.audit_log USING btree (created_at DESC);


--
-- Name: idx_auth_log_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_log_created ON public.auth_log USING btree (created_at DESC);


--
-- Name: idx_auth_log_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_log_email ON public.auth_log USING btree (email, created_at DESC);


--
-- Name: idx_delivery_audit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_delivery_audit ON public.delivery_log USING btree (audit_id);


--
-- Name: idx_delivery_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_delivery_created ON public.delivery_log USING btree (created_at DESC);


--
-- Name: idx_delivery_failed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_delivery_failed ON public.delivery_log USING btree (created_at DESC) WHERE (delivered = false);


--
-- Name: idx_delivery_pending_resend; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_delivery_pending_resend ON public.delivery_log USING btree (last_resend_at NULLS FIRST, created_at) WHERE ((delivered = false) AND (resolved = false));


--
-- Name: idx_email_log_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_log_created ON public.email_log USING btree (created_at DESC);


--
-- Name: idx_email_log_kind; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_email_log_kind ON public.email_log USING btree (kind, created_at DESC);


--
-- Name: idx_pending_wa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pending_wa ON public.pending_confirm USING btree (wa_number, expires_at DESC);


--
-- Name: idx_pipeline_cust_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pipeline_cust_trgm ON public.pipeline_tracker USING gin (customer_name public.gin_trgm_ops);


--
-- Name: idx_pipeline_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pipeline_user ON public.pipeline_tracker USING btree (user_id);


--
-- Name: idx_processed_msg_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_processed_msg_expires ON public.processed_message USING btree (expires_at);


--
-- Name: idx_processed_msg_wa; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_processed_msg_wa ON public.processed_message USING btree (wa_number, processed_at DESC);


--
-- Name: idx_sales_plan_tanggal; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sales_plan_tanggal ON public.sales_plan USING btree (tanggal);


--
-- Name: idx_sp_user_tgl; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sp_user_tgl ON public.sales_plan USING btree (user_id, tanggal);


--
-- Name: idx_st_reported; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_st_reported ON public.sales_todo USING btree (reported, tanggal);


--
-- Name: idx_st_user_tgl; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_st_user_tgl ON public.sales_todo USING btree (user_id, tanggal);


--
-- Name: idx_territory_am; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_territory_am ON public.master_territory USING btree (am_panggilan);


--
-- Name: idx_territory_kota; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_territory_kota ON public.master_territory USING gin (to_tsvector('indonesian'::regconfig, (kota)::text));


--
-- Name: idx_user_session_email_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_session_email_created ON public.user_session USING btree (email, created_at DESC);


--
-- Name: idx_user_session_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_session_expires ON public.user_session USING btree (expires_at);


--
-- Name: activity_log activity_log_pipeline_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_pipeline_id_fkey FOREIGN KEY (pipeline_id) REFERENCES public.pipeline_tracker(id) ON DELETE SET NULL;


--
-- Name: activity_log activity_log_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES public.sales_plan(id);


--
-- Name: activity_log activity_log_todo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_todo_id_fkey FOREIGN KEY (todo_id) REFERENCES public.sales_todo(id);


--
-- Name: activity_log activity_log_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.master_user(id) ON DELETE CASCADE;


--
-- Name: alert_log alert_log_escalation_for_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.alert_log
    ADD CONSTRAINT alert_log_escalation_for_fkey FOREIGN KEY (escalation_for) REFERENCES public.alert_log(id) ON DELETE SET NULL;


--
-- Name: deal_closed deal_closed_pipeline_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deal_closed
    ADD CONSTRAINT deal_closed_pipeline_id_fkey FOREIGN KEY (pipeline_id) REFERENCES public.pipeline_tracker(id) ON DELETE SET NULL;


--
-- Name: deal_closed deal_closed_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.deal_closed
    ADD CONSTRAINT deal_closed_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.master_user(id) ON DELETE CASCADE;


--
-- Name: delivery_log delivery_log_audit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_log
    ADD CONSTRAINT delivery_log_audit_id_fkey FOREIGN KEY (audit_id) REFERENCES public.audit_log(id) ON DELETE SET NULL;


--
-- Name: delivery_log delivery_log_parent_delivery_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_log
    ADD CONSTRAINT delivery_log_parent_delivery_id_fkey FOREIGN KEY (parent_delivery_id) REFERENCES public.delivery_log(id) ON DELETE SET NULL;


--
-- Name: pipeline_tracker pipeline_tracker_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pipeline_tracker
    ADD CONSTRAINT pipeline_tracker_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.master_user(id) ON DELETE CASCADE;


--
-- Name: sales_plan sales_plan_activity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_plan
    ADD CONSTRAINT sales_plan_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activity_log(id);


--
-- Name: sales_plan sales_plan_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_plan
    ADD CONSTRAINT sales_plan_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.master_user(id) ON DELETE CASCADE;


--
-- Name: sales_todo sales_todo_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales_todo
    ADD CONSTRAINT sales_todo_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.master_user(id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--


