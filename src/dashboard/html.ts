/**
 * Single-file dashboard. Vanilla JS, no build step, no external deps.
 * Token is read from the URL (?token=...) and forwarded as a header to /api/*.
 */

export const DASHBOARD_HTML = `<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width,initial-scale=1.0" />
<title>WRG CRM — Dashboard</title>
<style>
  :root {
    --bg: #0e1116; --panel: #161b22; --panel2: #1c2330;
    --border: #2a313c; --text: #e6edf3; --muted: #8b949e;
    --green: #3fb950; --red: #f85149; --amber: #d29922; --blue: #58a6ff;
    --accent: #f78166;
  }
  * { box-sizing: border-box; }
  html, body { margin: 0; padding: 0; background: var(--bg); color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    font-size: 14px; line-height: 1.5; }
  a { color: var(--blue); text-decoration: none; }
  header { padding: 14px 24px; border-bottom: 1px solid var(--border);
    display: flex; align-items: center; gap: 16px; justify-content: space-between; background: var(--panel); }
  header h1 { font-size: 16px; margin: 0; font-weight: 600; }
  header h1 .accent { color: var(--accent); }
  .meta { font-size: 12px; color: var(--muted); display: flex; gap: 12px; align-items: center; }
  .dot { display:inline-block; width:8px; height:8px; border-radius:50%; background:var(--muted); }
  .dot.ok { background: var(--green); }
  .dot.warn { background: var(--amber); }
  .dot.err { background: var(--red); }
  nav { display: flex; gap: 4px; padding: 0 24px; background: var(--panel);
    border-bottom: 1px solid var(--border); }
  nav button { background: transparent; border: 0; color: var(--muted);
    padding: 12px 16px; cursor: pointer; font-size: 13px; border-bottom: 2px solid transparent; }
  nav button.active { color: var(--text); border-bottom-color: var(--accent); }
  main { padding: 24px; }
  .grid { display: grid; gap: 16px; }
  .grid.cols-3 { grid-template-columns: repeat(3, 1fr); }
  .grid.cols-4 { grid-template-columns: repeat(4, 1fr); }
  .grid.cols-2 { grid-template-columns: repeat(2, 1fr); }
  @media (max-width: 900px) {
    .grid.cols-3, .grid.cols-4, .grid.cols-2 { grid-template-columns: 1fr; }
  }
  .card { background: var(--panel); border: 1px solid var(--border);
    border-radius: 8px; padding: 16px; }
  .card h2 { font-size: 13px; text-transform: uppercase; letter-spacing: 0.05em;
    color: var(--muted); margin: 0 0 12px 0; font-weight: 600; }
  .kpi { font-size: 28px; font-weight: 600; line-height: 1.2; }
  .kpi small { font-size: 13px; color: var(--muted); font-weight: 400; margin-left: 6px; }
  .row { display: flex; justify-content: space-between; padding: 6px 0;
    border-bottom: 1px solid var(--border); }
  .row:last-child { border-bottom: 0; }
  .row .label { color: var(--muted); }
  .row .val { font-weight: 500; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; color: var(--muted); font-weight: 500;
    padding: 8px 8px 8px 0; border-bottom: 1px solid var(--border); font-size: 11px;
    text-transform: uppercase; letter-spacing: 0.05em; }
  td { padding: 8px 8px 8px 0; border-bottom: 1px solid var(--border); vertical-align: top; }
  tr:last-child td { border-bottom: 0; }
  .pill { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px;
    font-weight: 500; }
  .pill.cold { background: #0d2a4a; color: #5a9eff; }
  .pill.warm { background: #423012; color: #e8a045; }
  .pill.hot { background: #4a1717; color: #f78166; }
  .pill.won { background: #103e1d; color: var(--green); }
  .pill.lost { background: #2d2d2d; color: var(--muted); }
  .pill.green { background: #103e1d; color: var(--green); }
  .pill.red { background: #4a1717; color: var(--red); }
  .pill.amber { background: #423012; color: var(--amber); }
  .bar { background: #2a313c; height: 6px; border-radius: 3px; overflow: hidden; }
  .bar-fill { height: 100%; background: var(--accent); }
  .empty { color: var(--muted); font-style: italic; padding: 12px 0; }
  .err-banner { background: #4a1717; color: var(--red); padding: 8px 14px;
    border-radius: 6px; margin-bottom: 16px; font-size: 13px; }
  .truncate { max-width: 280px; overflow: hidden; text-overflow: ellipsis;
    white-space: nowrap; }
  pre.json { background: var(--panel2); padding: 12px; border-radius: 6px;
    font-size: 12px; overflow-x: auto; }
  button.refresh { background: var(--panel2); color: var(--text);
    border: 1px solid var(--border); padding: 6px 12px; border-radius: 6px;
    cursor: pointer; font-size: 12px; }
  button.refresh:hover { background: var(--border); }
</style>
</head>
<body>
<header>
  <h1>WRG CRM <span class="accent">Dashboard</span></h1>
  <div class="meta">
    <span id="who" style="font-size:12px;color:var(--muted)"></span>
    <span><span id="health-dot" class="dot"></span> <span id="health-text">checking…</span></span>
    <span id="last-refresh">—</span>
    <button class="refresh" id="refresh-btn">↻ Refresh</button>
    <form method="POST" action="/auth/logout" style="margin:0">
      <button class="refresh" type="submit" id="logout-btn" style="display:none">Logout</button>
    </form>
  </div>
</header>
<nav>
  <button data-tab="overview" class="active">Overview</button>
  <button data-tab="activity">Activity</button>
  <button data-tab="pipeline">Pipeline</button>
  <button data-tab="ops">Ops Health</button>
  <button data-tab="export">Export</button>
</nav>
<main id="main"></main>

<script>
const params = new URLSearchParams(location.search);
const TOKEN = params.get('token') || '';
let activeTab = 'overview';
let refreshTimer = null;

async function api(path) {
  // Cookie session takes precedence; legacy token via Authorization header for fallback.
  const headers = TOKEN ? { authorization: 'Bearer ' + TOKEN } : {};
  const r = await fetch(path, { headers, credentials: 'same-origin' });
  if (!r.ok) throw new Error('HTTP ' + r.status);
  return r.json();
}

async function loadWho() {
  try {
    const me = await api('/api/me');
    if (me.mode === 'session') {
      document.getElementById('who').textContent = me.email;
      document.getElementById('logout-btn').style.display = 'inline-block';
    } else {
      document.getElementById('who').textContent = '(token auth)';
    }
  } catch { /* not logged in */ }
}

function fmtDate(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return d.toLocaleString('id-ID', { hour12: false, timeZone: 'Asia/Jakarta' });
}

function pillFor(status) {
  return '<span class="pill ' + status.toLowerCase() + '">' + status + '</span>';
}

function el(tag, attrs, ...children) {
  const e = document.createElement(tag);
  if (attrs) for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') e.className = v;
    else if (k === 'html') e.innerHTML = v;
    else e.setAttribute(k, v);
  }
  for (const c of children.flat()) {
    if (c == null) continue;
    if (typeof c === 'string') e.appendChild(document.createTextNode(c));
    else e.appendChild(c);
  }
  return e;
}

function setMain(html) { document.getElementById('main').innerHTML = html; }

async function renderOverview() {
  const d = await api('/api/overview');
  const s = d.summary;
  const teamPct = s.totalAmRoster > 0 ? Math.round(s.activeTeamCount/s.totalAmRoster*100) : 0;
  const cov = s.coveragePct;
  const hotHtml = s.hotDeals.length
    ? s.hotDeals.map(h => '<div class="row"><span>' +
        h.customer_name + ' <small style="color:var(--muted)">(' + h.nama_am + ')</small></span>' +
        pillFor(h.status) + ' Stage ' + h.stage + '</div>').join('')
    : '<div class="empty">Belum ada deal Hot / stage 3+ hari ini</div>';
  const attentionHtml = s.needAttention.length
    ? s.needAttention.map(a => '<div class="row"><span>' + a.nama_am +
        ' <small style="color:var(--muted)">(' + (a.area||'-') + ')</small></span>' +
        '<span>' + (a.plans > 0 ? a.plans + ' plan / 0 visit' : '0 kunjungan') + '</span></div>').join('')
    : '<div class="empty">Semua AM aktif hari ini ✓</div>';
  const topHtml = s.topPerformers.length
    ? s.topPerformers.map(t => '<div class="row"><span>' + t.nama_am +
        ' <small style="color:var(--muted)">(' + (t.area||'-') + ')</small></span><span>' +
        t.visits + ' kunjungan</span></div>').join('')
    : '<div class="empty">Belum ada kunjungan tercatat</div>';

  setMain(\`
    <div class="grid cols-4">
      <div class="card"><h2>Tim Aktif</h2>
        <div class="kpi">\${s.activeTeamCount}<small>/ \${s.totalAmRoster} AM (\${teamPct}%)</small></div>
        <div class="bar" style="margin-top:8px"><div class="bar-fill" style="width:\${teamPct}%"></div></div>
      </div>
      <div class="card"><h2>Total Kunjungan</h2>
        <div class="kpi">\${s.totalVisits}<small>hari ini</small></div></div>
      <div class="card"><h2>Plan</h2>
        <div class="kpi">\${s.totalPlans}<small>tercatat</small></div></div>
      <div class="card"><h2>Coverage</h2>
        <div class="kpi">\${cov}%<small>visit / plan</small></div>
        <div class="bar" style="margin-top:8px"><div class="bar-fill" style="width:\${cov}%"></div></div>
      </div>
    </div>
    <div class="grid cols-3" style="margin-top:16px">
      <div class="card"><h2>🔥 Hot Deals</h2>\${hotHtml}</div>
      <div class="card"><h2>⚠️ Perlu Perhatian</h2>\${attentionHtml}</div>
      <div class="card"><h2>📈 Top Performer</h2>\${topHtml}</div>
    </div>
    <div class="card" style="margin-top:16px">
      <h2>Per-AM Hari Ini</h2>
      <table><thead><tr><th>AM</th><th>Area</th><th>Visit</th><th>Plan</th><th>Last activity</th></tr></thead><tbody>
        \${d.amStats.map(a => '<tr><td>'+a.nama_am+'</td><td>'+(a.area||'-')+
          '</td><td>'+a.visits+'</td><td>'+a.plans+'</td><td>'+fmtDate(a.last_activity_at)+'</td></tr>').join('')}
      </tbody></table>
    </div>
  \`);
}

async function renderActivity() {
  const rows = await api('/api/activity?limit=50');
  setMain(\`
    <div class="card"><h2>Recent Activity (50)</h2>
      <table><thead><tr><th>Waktu</th><th>AM</th><th>Customer</th><th>Hasil</th><th>Next</th></tr></thead><tbody>
        \${rows.map(r => '<tr><td>'+fmtDate(r.created_at)+'</td><td>'+r.nama_am+
          '</td><td>'+r.customer_name+'</td><td class="truncate">'+(r.hasil||'-')+
          '</td><td class="truncate">'+(r.next_action||'-')+'</td></tr>').join('')}
        \${rows.length === 0 ? '<tr><td colspan="5" class="empty">Belum ada activity_log</td></tr>' : ''}
      </tbody></table>
    </div>
  \`);
}

async function renderPipeline() {
  const d = await api('/api/pipeline');
  const max = Math.max(1, ...d.byStatus.map(s => s.count));
  const stageHtml = d.byStatus.map(s => \`
    <div class="row"><span>\${pillFor(s.status)} \${s.status}</span><span>\${s.count}</span></div>
    <div class="bar" style="margin-bottom:8px"><div class="bar-fill" style="width:\${(s.count/max)*100}%"></div></div>
  \`).join('');
  setMain(\`
    <div class="grid cols-2">
      <div class="card"><h2>Status Breakdown</h2>\${stageHtml || '<div class="empty">Empty pipeline</div>'}</div>
      <div class="card"><h2>Stage × Status Matrix</h2>
        <table><thead><tr><th>Stage</th><th>Status</th><th>Count</th></tr></thead><tbody>
          \${d.stageBreakdown.map(r => '<tr><td>'+r.stage+'</td><td>'+pillFor(r.status)+
            '</td><td>'+r.count+'</td></tr>').join('')}
          \${d.stageBreakdown.length === 0 ? '<tr><td colspan="3" class="empty">—</td></tr>' : ''}
        </tbody></table>
      </div>
    </div>
    <div class="card" style="margin-top:16px"><h2>Top Deals (Hot / Stage ≥ 3 / Won)</h2>
      <table><thead><tr><th>Customer</th><th>AM</th><th>Produk</th><th>Stage</th><th>Status</th><th>Last update</th></tr></thead><tbody>
        \${d.topDeals.map(t => '<tr><td>'+t.customer_name+'</td><td>'+t.nama_am+
          '</td><td>'+(t.produk||'-')+'</td><td>'+t.stage+'</td><td>'+pillFor(t.status)+
          '</td><td>'+fmtDate(t.updated_at)+'</td></tr>').join('')}
        \${d.topDeals.length === 0 ? '<tr><td colspan="6" class="empty">Belum ada deal panas</td></tr>' : ''}
      </tbody></table>
    </div>
  \`);
}

async function renderOps() {
  const [d, alerts] = await Promise.all([api('/api/ops'), api('/api/alerts?limit=10')]);
  const dot = d.resend.exhausted > 0 ? 'err' : (d.resend.pending > 0 ? 'warn' : 'ok');
  const rateHtml = d.rateLimitedRecent.length
    ? d.rateLimitedRecent.map(r => '<div class="row"><span>'+r.wa_number+'</span><span>'+
        r.count+' hit ('+fmtDate(r.last_hit)+')</span></div>').join('')
    : '<div class="empty">Tidak ada rate limit hit dalam 1 jam terakhir ✓</div>';
  const failHtml = d.failedDeliveries.length
    ? '<table><thead><tr><th>Waktu</th><th>Source</th><th>Target</th><th>Retry</th><th>Error</th></tr></thead><tbody>' +
      d.failedDeliveries.map(f => '<tr><td>'+fmtDate(f.created_at)+'</td><td>'+f.source+
        '</td><td>'+f.target+'</td><td>'+f.resend_count+'</td><td class="truncate">'+(f.error||'-')+
        '</td></tr>').join('') + '</tbody></table>'
    : '<div class="empty">Semua delivery sukses ✓</div>';
  const auditHtml = d.auditSummary.map(a => {
    const cls = a.status === 'SUCCESS' ? 'green' : (a.status === 'FAILED' ? 'red' : 'amber');
    return '<div class="row"><span><span class="pill '+cls+'">'+a.status+'</span></span><span>'+a.count+'</span></div>';
  }).join('') || '<div class="empty">—</div>';
  const alertsHtml = alerts.length
    ? '<table><thead><tr><th>Waktu</th><th>Level</th><th>Kind</th><th>Title</th><th>Channels</th></tr></thead><tbody>' +
      alerts.map(a => {
        const cls = a.level === 'critical' ? 'red' : a.level === 'warn' ? 'amber' : 'green';
        const chans = (a.channels_delivered || []).map(c =>
          '<span class="pill ' + (c.delivered ? 'green' : 'red') + '">' + c.channel + '</span>'
        ).join(' ');
        return '<tr><td>'+fmtDate(a.created_at)+'</td><td><span class="pill '+cls+'">'+
          a.level+'</span></td><td>'+a.kind+'</td><td class="truncate">'+a.title+'</td><td>'+chans+'</td></tr>';
      }).join('') + '</tbody></table>'
    : '<div class="empty">Belum pernah ada alert ✓</div>';

  setMain(\`
    <div class="grid cols-3">
      <div class="card"><h2>Resend Pending <span class="dot \${dot}"></span></h2>
        <div class="kpi">\${d.resend.pending}<small>menunggu retry</small></div></div>
      <div class="card"><h2>Resolved (24h)</h2>
        <div class="kpi">\${d.resend.resolved24h}</div></div>
      <div class="card"><h2>Exhausted</h2>
        <div class="kpi">\${d.resend.exhausted}<small>max attempt habis</small></div></div>
    </div>
    <div class="grid cols-2" style="margin-top:16px">
      <div class="card"><h2>Rate-limit Hits (1 jam)</h2>\${rateHtml}</div>
      <div class="card"><h2>Audit Status (24 jam)</h2>\${auditHtml}</div>
    </div>
    <div class="card" style="margin-top:16px"><h2>Failed Deliveries (unresolved)</h2>\${failHtml}</div>
    <div class="card" style="margin-top:16px"><h2>Recent Alerts</h2>\${alertsHtml}</div>
  \`);
}

function todayStr() { return new Date().toISOString().slice(0, 10); }
function weekAgoStr() {
  const d = new Date(); d.setDate(d.getDate() - 6);
  return d.toISOString().slice(0, 10);
}

async function renderExport() {
  const from = weekAgoStr();
  const to = todayStr();
  const url = (path, range) => {
    const u = new URL(path, location.origin);
    u.searchParams.set('token', TOKEN);
    if (range) { u.searchParams.set('from', range.from); u.searchParams.set('to', range.to); }
    return u.toString();
  };
  setMain(\`
    <div class="card"><h2>Date Range (untuk Activity/Plans/Deals/Digest)</h2>
      <div style="display:flex;gap:12px;align-items:center;flex-wrap:wrap">
        <label>From:
          <input type="date" id="exp-from" value="\${from}"
            style="background:var(--panel2);color:var(--text);border:1px solid var(--border);padding:6px;border-radius:4px"/>
        </label>
        <label>To:
          <input type="date" id="exp-to" value="\${to}"
            style="background:var(--panel2);color:var(--text);border:1px solid var(--border);padding:6px;border-radius:4px"/>
        </label>
      </div>
    </div>
    <div class="grid cols-2" style="margin-top:16px">
      <div class="card"><h2>CSV Downloads</h2>
        <p style="color:var(--muted);font-size:12px">Excel-friendly UTF-8 dengan BOM. Buka di Excel/Sheets/Numbers.</p>
        <div style="display:grid;gap:8px;margin-top:8px">
          <a id="link-pipeline" class="btn">📊 Pipeline (semua, tanpa filter tanggal)</a>
          <a id="link-activity" class="btn">📋 Activity Log (range)</a>
          <a id="link-plans" class="btn">📅 Sales Plans (range)</a>
          <a id="link-deals" class="btn">💰 Deals Closed (range)</a>
        </div>
      </div>
      <div class="card"><h2>Weekly Digest (HTML)</h2>
        <p style="color:var(--muted);font-size:12px">
          Print-friendly report dengan KPI + daily breakdown + per-AM + closed deals + hot pipeline.
          Cetak ke PDF lewat Cmd+P / Ctrl+P.
        </p>
        <a id="link-digest" class="btn" target="_blank">🗂️ Open Weekly Digest</a>
      </div>
    </div>
    <style>
      .btn { display: inline-block; background: var(--panel2); border: 1px solid var(--border);
        color: var(--text); padding: 10px 14px; border-radius: 6px; text-align: left;
        text-decoration: none; font-size: 13px; transition: background 0.1s; }
      .btn:hover { background: var(--border); }
    </style>
  \`);
  const updateLinks = () => {
    const range = { from: document.getElementById('exp-from').value, to: document.getElementById('exp-to').value };
    document.getElementById('link-pipeline').href = url('/export/pipeline.csv');
    document.getElementById('link-activity').href = url('/export/activity.csv', range);
    document.getElementById('link-plans').href = url('/export/plans.csv', range);
    document.getElementById('link-deals').href = url('/export/deals.csv', range);
    document.getElementById('link-digest').href = url('/export/digest', range);
  };
  document.getElementById('exp-from').addEventListener('change', updateLinks);
  document.getElementById('exp-to').addEventListener('change', updateLinks);
  updateLinks();
}

const renderers = { overview: renderOverview, activity: renderActivity, pipeline: renderPipeline, ops: renderOps, export: renderExport };

async function refresh() {
  try {
    await renderers[activeTab]();
    document.getElementById('health-dot').className = 'dot ok';
    document.getElementById('health-text').textContent = 'OK';
  } catch (e) {
    document.getElementById('health-dot').className = 'dot err';
    document.getElementById('health-text').textContent = 'Error: ' + e.message;
    setMain('<div class="err-banner">Gagal load data: ' + e.message +
      '. Pastikan ?token=... di URL benar.</div>');
  }
  document.getElementById('last-refresh').textContent =
    'Refresh: ' + new Date().toLocaleTimeString('id-ID', { hour12: false });
}

document.querySelectorAll('nav button').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('nav button').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    activeTab = btn.dataset.tab;
    refresh();
  });
});
document.getElementById('refresh-btn').addEventListener('click', refresh);

loadWho();
refresh();
refreshTimer = setInterval(refresh, 30000);
</script>
</body>
</html>`;
