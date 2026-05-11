import Fastify, { type FastifyRequest, type FastifyReply } from 'fastify';
import { config } from './config.js';
import { processInbound } from './dispatcher.js';
import { startScheduler } from './scheduler.js';
import { runDailySummary } from './summary/index.js';
import { listDeliveries } from './repo/delivery.js';
import { processResendBatch } from './resend.js';
import { getResendStats } from './repo/resend.js';
import { globalLimiter, sweepLimiters } from './limiters.js';
import { DASHBOARD_HTML } from './dashboard/html.js';
import {
  fetchOverview,
  fetchRecentActivity,
  fetchPipelineSnapshot,
  fetchOps,
} from './dashboard/queries.js';
import { checkExhaustedAndAlert, checkAndEscalate, fireAlert, listRecentAlerts } from './alerts/index.js';
import { serializeCsv, exportFilename } from './exports/csv.js';
import {
  exportPipeline,
  exportActivity,
  exportPlans,
  exportDeals,
} from './exports/queries.js';
import { renderWeeklyDigest } from './exports/digest.js';
import { sendWeeklyDigestEmail, recordDigestSend } from './email/digest.js';
import { todayWib } from './util/dateid.js';
import {
  requireAuth,
  buildSessionCookie,
  clearCookie,
  SESSION_COOKIE,
  getSessionTokenFromCookie,
} from './auth/middleware.js';
import {
  createSession,
  destroySession,
  logAuthEvent,
  cleanupExpiredSessions,
} from './auth/session.js';
import {
  isConfigured as googleConfigured,
  buildAuthorizeUrl,
  exchangeCode,
  fetchUserInfo,
  newState,
  verifyAccess,
} from './auth/google.js';
import { renderLoginPage } from './auth/pages.js';
import { SETUP_HTML } from './setup/page.js';
import { checkAll } from './setup/status.js';
import { readEnvSections } from './setup/env.js';
import { listAms, createAm, toggleAmAktif, type CreateAmInput } from './setup/users.js';
import { testWaSend, testAlertChannels, testEmailDigest, testOAuthConfig, testLlm } from './setup/tests.js';
import type { InboundMessage } from './types.js';

// In-memory CSRF state store for OAuth flow (single-instance OK).
const oauthStates = new Map<string, { createdAt: number; returnTo?: string }>();
const OAUTH_STATE_TTL_MS = 10 * 60_000;
function sweepOauthStates() {
  const now = Date.now();
  for (const [k, v] of oauthStates) {
    if (now - v.createdAt > OAUTH_STATE_TTL_MS) oauthStates.delete(k);
  }
}

const app = Fastify({ logger: { level: 'info' } });

app.get('/health', async () => ({ ok: true, ts: new Date().toISOString() }));

/**
 * Backward-compat alias of requireAuth (api mode).
 * Endpoint protection: cookie session OR Authorization: Bearer DASHBOARD_TOKEN.
 */
async function requireDashboardToken(req: FastifyRequest, reply: FastifyReply): Promise<boolean> {
  const ctx = await requireAuth(req, reply, 'api');
  return ctx !== null;
}

// ── Auth routes ────────────────────────────────────────────────────────────
app.get<{ Querystring: { returnTo?: string } }>('/login', async (req, reply) => {
  reply.type('text/html; charset=utf-8').send(renderLoginPage(req.query.returnTo));
});

app.get<{ Querystring: { returnTo?: string } }>('/auth/google', async (req, reply) => {
  if (!googleConfigured()) {
    return reply.status(503).send({ ok: false, error: 'google_oauth_not_configured' });
  }
  const state = newState();
  oauthStates.set(state, { createdAt: Date.now(), returnTo: req.query.returnTo });
  return reply.redirect(buildAuthorizeUrl(state));
});

app.get<{ Querystring: { code?: string; state?: string; error?: string } }>(
  '/auth/google/callback',
  async (req, reply) => {
    sweepOauthStates();
    const { code, state, error } = req.query;
    const ip = req.ip;
    const ua = req.headers['user-agent'];
    if (error) {
      await logAuthEvent({ event: 'login_failed', reason: `provider error: ${error}`, ip, userAgent: ua });
      return reply.status(400).send({ ok: false, error: `provider_error: ${error}` });
    }
    if (!code || !state) {
      return reply.status(400).send({ ok: false, error: 'missing_code_or_state' });
    }
    const stateEntry = oauthStates.get(state);
    if (!stateEntry) {
      await logAuthEvent({ event: 'login_failed', reason: 'invalid state', ip, userAgent: ua });
      return reply.status(400).send({ ok: false, error: 'invalid_or_expired_state' });
    }
    oauthStates.delete(state);

    try {
      const tok = await exchangeCode(code);
      const user = await fetchUserInfo(tok.access_token);
      const denyReason = verifyAccess(user);
      if (denyReason) {
        await logAuthEvent({ email: user.email, event: 'login_failed', reason: denyReason, ip, userAgent: ua });
        return reply.status(403).send({ ok: false, error: 'access_denied', reason: denyReason });
      }
      const sessionToken = await createSession({
        email: user.email,
        name: user.name,
        picture: user.picture,
        ip,
        userAgent: typeof ua === 'string' ? ua : undefined,
      });
      await logAuthEvent({ email: user.email, event: 'login_success', ip, userAgent: ua });
      reply.header(
        'set-cookie',
        buildSessionCookie(sessionToken, config.auth.sessionTtlDays * 86400),
      );
      const target = stateEntry.returnTo || '/dashboard';
      return reply.redirect(target);
    } catch (err) {
      const reason = (err as Error).message;
      await logAuthEvent({ event: 'login_failed', reason, ip, userAgent: ua });
      return reply.status(500).send({ ok: false, error: 'oauth_flow_failed', reason });
    }
  },
);

app.post('/auth/logout', async (req, reply) => {
  const token = getSessionTokenFromCookie(req);
  if (token) {
    await destroySession(token);
    await logAuthEvent({ event: 'logout', ip: req.ip, userAgent: req.headers['user-agent'] });
  }
  reply.header('set-cookie', clearCookie(SESSION_COOKIE));
  return reply.redirect('/login');
});

// "Who am I" — dashboard JS calls this to show logged-in user.
app.get('/api/me', async (req, reply) => {
  const ctx = await requireAuth(req, reply, 'api');
  if (!ctx) return;
  if (ctx.session) {
    return reply.send({ ok: true, mode: 'session', email: ctx.session.email,
      name: ctx.session.name, picture: ctx.session.picture });
  }
  return reply.send({ ok: true, mode: 'token' });
});

// ── Dashboard (HTML page) ─────────────────────────────────────────────────
app.get('/dashboard', async (req, reply) => {
  const ctx = await requireAuth(req, reply, 'page');
  if (!ctx) return;
  reply.type('text/html; charset=utf-8').send(DASHBOARD_HTML);
});

// ── Setup page (HTML) ─────────────────────────────────────────────────────
app.get('/setup', async (req, reply) => {
  const ctx = await requireAuth(req, reply, 'page');
  if (!ctx) return;
  reply.type('text/html; charset=utf-8').send(SETUP_HTML);
});

app.get('/api/setup/status', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  const rows = await checkAll();
  return reply.send({ ok: true, rows });
});

app.get('/api/setup/env', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  const sections = await readEnvSections();
  return reply.send({ ok: true, sections });
});

app.get('/api/setup/users', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  const rows = await listAms();
  return reply.send({ ok: true, rows });
});

app.post<{ Body: CreateAmInput }>('/api/setup/users', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  const r = await createAm(req.body || ({} as CreateAmInput));
  if ('error' in r) return reply.status(400).send({ ok: false, error: r.error });
  return reply.send({ ok: true, row: r });
});

app.patch<{ Params: { id: string }; Body: { aktif: boolean } }>(
  '/api/setup/users/:id',
  async (req, reply) => {
    if (!(await requireDashboardToken(req, reply))) return;
    const id = parseInt(req.params.id, 10);
    if (!Number.isFinite(id)) {
      return reply.status(400).send({ ok: false, error: 'invalid id' });
    }
    const r = await toggleAmAktif(id, Boolean(req.body?.aktif));
    if (!r.ok) return reply.status(404).send({ ok: false, error: r.error });
    return reply.send({ ok: true });
  },
);

app.post('/api/setup/test/wa', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  return reply.send(await testWaSend());
});

app.post('/api/setup/test/alert', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  return reply.send(await testAlertChannels());
});

app.post('/api/setup/test/email', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  return reply.send(await testEmailDigest());
});

app.post('/api/setup/test/oauth', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  return reply.send(testOAuthConfig());
});

app.post('/api/setup/test/llm', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  return reply.send(await testLlm());
});

app.get('/api/overview', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  return reply.send(await fetchOverview());
});

app.get<{ Querystring: { limit?: string } }>('/api/activity', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  const limit = req.query.limit ? parseInt(req.query.limit, 10) : 30;
  return reply.send(await fetchRecentActivity(limit));
});

app.get('/api/pipeline', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  return reply.send(await fetchPipelineSnapshot());
});

app.get('/api/ops', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  return reply.send(await fetchOps());
});

app.post<{ Body: InboundMessage }>('/webhook', async (req, reply) => {
  const ipKey = req.ip || 'unknown';
  const ipRl = globalLimiter.check(ipKey);
  if (!ipRl.allowed) {
    return reply
      .status(429)
      .header('Retry-After', String(ipRl.retryAfterSec))
      .send({ ok: false, error: 'rate_limited_global', retryAfterSec: ipRl.retryAfterSec });
  }

  const body = req.body;
  if (!body || typeof body.from !== 'string' || typeof body.text !== 'string') {
    return reply.status(400).send({ ok: false, error: 'invalid_payload' });
  }
  const outcome = await processInbound(body);
  if (outcome.rateLimited) {
    return reply
      .status(429)
      .header('Retry-After', String(outcome.retryAfterSec ?? 60))
      .send({ ok: false, error: 'rate_limited_per_wa', retryAfterSec: outcome.retryAfterSec });
  }
  return reply.send({ ok: true, ...outcome });
});

app.get<{
  Querystring: { status?: 'all' | 'failed' | 'success'; since?: string; limit?: string };
}>('/ops/deliveries', async (req, reply) => {
  const { status, since, limit } = req.query;
  if (status && !['all', 'failed', 'success'].includes(status)) {
    return reply.status(400).send({ ok: false, error: 'status must be all|failed|success' });
  }
  if (since && Number.isNaN(Date.parse(since))) {
    return reply.status(400).send({ ok: false, error: 'since must be ISO timestamp' });
  }
  const rows = await listDeliveries({
    status: status ?? 'all',
    since,
    limit: limit ? parseInt(limit, 10) : 100,
  });
  return reply.send({ ok: true, count: rows.length, rows });
});

app.post('/ops/resend-failures', async (_req, reply) => {
  const r = await processResendBatch();
  return reply.send({ ok: true, ...r });
});

app.get('/ops/resend-stats', async (_req, reply) => {
  const s = await getResendStats();
  return reply.send({ ok: true, ...s });
});

app.post('/ops/alerts/check', async (_req, reply) => {
  const r = await checkExhaustedAndAlert();
  return reply.send({ ok: true, ...r });
});

app.post('/ops/alerts/escalate', async (_req, reply) => {
  const r = await checkAndEscalate();
  return reply.send({ ok: true, ...r });
});

app.post('/ops/alerts/test', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  const a = await fireAlert({
    kind: 'test',
    level: 'info',
    title: 'Test alert from /ops/alerts/test',
    body: 'Kalau pesan ini sampai, alerting wiring sudah benar.',
    payload: { ts: new Date().toISOString() },
  });
  return reply.send({ ok: true, alert: a });
});

app.get('/api/alerts', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  const limit = (req.query as { limit?: string } | undefined)?.limit;
  return reply.send(await listRecentAlerts(limit ? parseInt(limit, 10) : 20));
});

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

function parseRange(q: Record<string, string | undefined>): { from?: string; to?: string } | { error: string } {
  const out: { from?: string; to?: string } = {};
  if (q.from) {
    if (!DATE_RE.test(q.from)) return { error: 'from must be YYYY-MM-DD' };
    out.from = q.from;
  }
  if (q.to) {
    if (!DATE_RE.test(q.to)) return { error: 'to must be YYYY-MM-DD' };
    out.to = q.to;
  }
  return out;
}

function sendCsv(reply: FastifyReply, filename: string, body: string): FastifyReply {
  return reply
    .header('content-type', 'text/csv; charset=utf-8')
    .header('content-disposition', `attachment; filename="${filename}"`)
    .send(body);
}

app.get('/export/pipeline.csv', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  const rows = await exportPipeline();
  const csv = serializeCsv({
    headers: ['id', 'customer_name', 'nama_am', 'area', 'produk', 'nilai_deal',
              'stage', 'status', 'note', 'created_at', 'updated_at'],
    rows,
    row: (r) => [r.id, r.customer_name, r.nama_am, r.area, r.produk, r.nilai_deal,
                 r.stage, r.status, r.note, r.created_at, r.updated_at],
  });
  return sendCsv(reply, exportFilename('pipeline'), csv);
});

app.get<{ Querystring: { from?: string; to?: string } }>('/export/activity.csv', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  const range = parseRange(req.query);
  if ('error' in range) return reply.status(400).send({ ok: false, error: range.error });
  const rows = await exportActivity(range);
  const csv = serializeCsv({
    headers: ['id', 'tanggal', 'nama_am', 'area', 'customer_name', 'tujuan',
              'hasil', 'next_action', 'source', 'pipeline_id', 'created_at'],
    rows,
    row: (r) => [r.id, r.tanggal, r.nama_am, r.area, r.customer_name, r.tujuan,
                 r.hasil, r.next_action, r.source, r.pipeline_id, r.created_at],
  });
  const suffix = range.from || range.to ? `${range.from || 'all'}_${range.to || 'all'}` : '';
  return sendCsv(reply, exportFilename('activity', suffix), csv);
});

app.get<{ Querystring: { from?: string; to?: string } }>('/export/plans.csv', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  const range = parseRange(req.query);
  if ('error' in range) return reply.status(400).send({ ok: false, error: range.error });
  const rows = await exportPlans(range);
  const csv = serializeCsv({
    headers: ['id', 'tanggal', 'nama_am', 'area', 'customer_name', 'tujuan',
              'goal', 'seq', 'created_at'],
    rows,
    row: (r) => [r.id, r.tanggal, r.nama_am, r.area, r.customer_name, r.tujuan,
                 r.goal, r.seq, r.created_at],
  });
  const suffix = range.from || range.to ? `${range.from || 'all'}_${range.to || 'all'}` : '';
  return sendCsv(reply, exportFilename('plans', suffix), csv);
});

app.get<{ Querystring: { from?: string; to?: string } }>('/export/deals.csv', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  const range = parseRange(req.query);
  if ('error' in range) return reply.status(400).send({ ok: false, error: range.error });
  const rows = await exportDeals(range);
  const csv = serializeCsv({
    headers: ['id', 'tanggal_closed', 'nama_am', 'area', 'customer_name',
              'produk', 'nilai_deal', 'catatan'],
    rows,
    row: (r) => [r.id, r.tanggal_closed, r.nama_am, r.area, r.customer_name,
                 r.produk, r.nilai_deal, r.catatan],
  });
  const suffix = range.from || range.to ? `${range.from || 'all'}_${range.to || 'all'}` : '';
  return sendCsv(reply, exportFilename('deals', suffix), csv);
});

app.post<{ Body?: { from?: string; to?: string; dryRun?: boolean } }>(
  '/ops/email-digest',
  async (req, reply) => {
    if (!(await requireDashboardToken(req, reply))) return;
    const body = req.body ?? {};
    const range = body.from || body.to ? parseRange(body as Record<string, string | undefined>) : {};
    if ('error' in range) return reply.status(400).send({ ok: false, error: range.error });

    const r = await sendWeeklyDigestEmail({
      range: range.from && range.to ? { from: range.from, to: range.to } : undefined,
      transportMode: body.dryRun ? 'json' : undefined,
    });
    await recordDigestSend(r);
    return reply.send({ ok: true, ...r });
  },
);

app.get<{ Querystring: { from?: string; to?: string } }>('/export/digest', async (req, reply) => {
  if (!(await requireDashboardToken(req, reply))) return;
  const range = parseRange(req.query);
  if ('error' in range) return reply.status(400).send({ ok: false, error: range.error });
  // Default ke 7 hari terakhir kalau tidak di-set.
  const to = range.to || todayWib();
  const from = range.from || (() => {
    const d = new Date(to + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() - 6);
    return d.toISOString().slice(0, 10);
  })();
  const html = await renderWeeklyDigest(from, to);
  return reply.type('text/html; charset=utf-8').send(html);
});

app.post<{ Body?: { date?: string } }>('/summary/run', async (req, reply) => {
  const date = req.body?.date;
  if (date && !/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    return reply.status(400).send({ ok: false, error: 'date harus YYYY-MM-DD' });
  }
  const r = await runDailySummary(date, 'manual');
  return reply.send({
    ok: true,
    tanggal: r.tanggal,
    delivered: r.sent.delivered,
    target: r.sent.target,
    text: r.text,
  });
});

const start = async () => {
  try {
    await app.listen({ port: config.port, host: '0.0.0.0' });
    app.log.info(`WRG CRM webhook listening on :${config.port} (WA mode=${config.wa.sendMode})`);
    startScheduler(app.log);

    // Sweep expired rate-limit buckets every 5 minutes to bound memory.
    const sweepInterval = setInterval(() => {
      const r = sweepLimiters();
      if (r.perWa + r.global > 0) {
        app.log.info({ ...r }, 'rate-limit sweep');
      }
    }, 5 * 60_000);
    sweepInterval.unref();
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
};
start();
