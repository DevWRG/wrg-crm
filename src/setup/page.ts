export const SETUP_HTML = `<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>WRG CRM — Setup</title>
<style>
  :root {
    --bg: #0e1116; --panel: #161b22; --panel2: #1c2330;
    --border: #2a313c; --text: #e6edf3; --muted: #8b949e;
    --green: #3fb950; --red: #f85149; --amber: #d29922; --blue: #58a6ff;
    --accent: #f78166;
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    font-size: 14px; line-height: 1.5; }
  a { color: var(--blue); text-decoration: none; }
  header { padding: 14px 24px; border-bottom: 1px solid var(--border);
    display: flex; align-items: center; gap: 16px; justify-content: space-between; background: var(--panel); }
  header h1 { font-size: 16px; margin: 0; font-weight: 600; }
  header h1 .accent { color: var(--accent); }
  main { padding: 24px; max-width: 1200px; margin: 0 auto; }
  section.card { background: var(--panel); border: 1px solid var(--border);
    border-radius: 8px; padding: 20px; margin-bottom: 16px; }
  section.card h2 { font-size: 13px; text-transform: uppercase; letter-spacing: 0.05em;
    color: var(--muted); margin: 0 0 16px 0; font-weight: 600; }
  .row { display: flex; align-items: center; gap: 12px; padding: 8px 0;
    border-bottom: 1px solid var(--border); }
  .row:last-child { border-bottom: 0; }
  .dot { width: 10px; height: 10px; border-radius: 50%; flex-shrink: 0; }
  .dot.ok { background: var(--green); }
  .dot.err { background: var(--red); }
  .dot.warn { background: var(--amber); }
  .dot.idle { background: var(--muted); }
  .label { font-weight: 500; min-width: 160px; }
  .detail { color: var(--muted); font-size: 12px; flex: 1; }
  button.btn, a.btn { background: var(--panel2); color: var(--text);
    border: 1px solid var(--border); padding: 6px 14px; border-radius: 6px;
    font-size: 12px; cursor: pointer; transition: background 0.1s;
    font-family: inherit; }
  button.btn:hover, a.btn:hover { background: var(--border); }
  button.btn.primary { background: var(--accent); border-color: var(--accent); color: #1a1a1a; }
  button.btn.primary:hover { opacity: 0.9; }
  button.btn.danger { background: transparent; border-color: var(--red); color: var(--red); }
  button.btn:disabled { opacity: 0.5; cursor: not-allowed; }
  table { width: 100%; border-collapse: collapse; }
  th { text-align: left; color: var(--muted); font-weight: 500;
    padding: 8px 8px 8px 0; border-bottom: 1px solid var(--border); font-size: 11px;
    text-transform: uppercase; letter-spacing: 0.05em; }
  td { padding: 8px 8px 8px 0; border-bottom: 1px solid var(--border); vertical-align: middle; }
  tr:last-child td { border-bottom: 0; }
  input[type="text"], select { background: var(--panel2); color: var(--text);
    border: 1px solid var(--border); padding: 6px 10px; border-radius: 4px;
    font-family: inherit; font-size: 13px; }
  input[type="text"]:focus, select:focus { outline: 1px solid var(--accent); }
  .form-row { display: grid; grid-template-columns: repeat(4, 1fr) auto; gap: 8px;
    align-items: center; margin-top: 12px; }
  .pill { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px;
    font-weight: 500; }
  .pill.green { background: #103e1d; color: var(--green); }
  .pill.red { background: #4a1717; color: var(--red); }
  .pill.amber { background: #423012; color: var(--amber); }
  .pill.grey { background: #2a313c; color: var(--muted); }
  pre.snippet { background: var(--panel2); padding: 10px 12px; border-radius: 4px;
    font-size: 12px; overflow-x: auto; margin: 0; position: relative;
    border: 1px solid var(--border); }
  .snippet-row { display: flex; gap: 8px; align-items: stretch; margin-bottom: 8px; }
  .snippet-row pre { flex: 1; margin: 0; }
  .toast { position: fixed; bottom: 24px; right: 24px; background: var(--panel);
    border: 1px solid var(--border); padding: 12px 16px; border-radius: 6px;
    box-shadow: 0 4px 12px rgba(0,0,0,0.5); opacity: 0; transition: opacity 0.2s;
    pointer-events: none; max-width: 400px; }
  .toast.show { opacity: 1; }
  .toast.ok { border-color: var(--green); }
  .toast.err { border-color: var(--red); }
  .section-comment { color: var(--muted); font-size: 11px; padding: 2px 0; font-style: italic; }
  .env-entry { display: grid; grid-template-columns: 220px 1fr; gap: 12px;
    padding: 4px 0; align-items: baseline; }
  .env-key { font-family: ui-monospace, "SF Mono", Menlo, monospace;
    color: var(--blue); font-size: 12px; }
  .env-val { font-family: ui-monospace, "SF Mono", Menlo, monospace;
    color: var(--text); font-size: 12px; word-break: break-all; }
  .env-val.masked { color: var(--amber); }
  .env-val.empty { color: var(--muted); font-style: italic; }
  details { margin-top: 8px; }
  summary { cursor: pointer; color: var(--muted); font-size: 12px; padding: 4px 0; }
  summary:hover { color: var(--text); }
</style>
</head>
<body>
<header>
  <h1>WRG CRM <span class="accent">Setup</span></h1>
  <div>
    <a class="btn" href="/dashboard">← Dashboard</a>
  </div>
</header>
<main>
  <section class="card">
    <h2>1. Service Health</h2>
    <div id="status-list"><div class="detail">Loading…</div></div>
  </section>

  <section class="card">
    <h2>2. Integration Tests</h2>
    <div class="detail" style="margin-bottom: 12px">
      Klik untuk fire test ke channel masing-masing. Aman dipakai — bukan WA spam.
    </div>
    <div class="row">
      <div class="label">WhatsApp gateway</div>
      <div class="detail">Kirim test message ke <code>WA_HOD_GROUP_ID</code></div>
      <button class="btn" data-test="wa">Test send</button>
    </div>
    <div class="row">
      <div class="label">Alert channels</div>
      <div class="detail">Fire test alert ke log + http-webhook + wa-dm</div>
      <button class="btn" data-test="alert">Test alert</button>
    </div>
    <div class="row">
      <div class="label">Email digest</div>
      <div class="detail">Render weekly digest, kirim ke EMAIL_HOD_RECIPIENTS (atau dry-run kalau disabled)</div>
      <button class="btn" data-test="email">Test email</button>
    </div>
    <div class="row">
      <div class="label">OAuth config</div>
      <div class="detail">Validate Google client setup (tanpa actual login)</div>
      <button class="btn" data-test="oauth">Verify</button>
    </div>
    <div id="test-result" style="margin-top: 12px; display: none">
      <pre class="snippet" id="test-output"></pre>
    </div>
  </section>

  <section class="card">
    <h2>3. Master User (Account Managers)</h2>
    <table id="user-table">
      <thead><tr><th>Nama</th><th>WA Number</th><th>Area</th><th>Role</th><th>Aktif</th><th>Activity 30d</th><th>Last seen</th><th></th></tr></thead>
      <tbody><tr><td colspan="8" class="detail">Loading…</td></tr></tbody>
    </table>
    <form id="add-user-form" class="form-row">
      <input name="wa_number" placeholder="6281234567890" pattern="[0-9]{8,15}" required />
      <input name="nama_am" placeholder="Nama lengkap" required />
      <input name="area" placeholder="Area (e.g. Jakarta)" />
      <select name="role"><option value="AM">AM</option><option value="OSP">OSP</option><option value="ADMIN">ADMIN</option></select>
      <button class="btn primary" type="submit">+ Tambah</button>
    </form>
    <div class="detail" style="margin-top: 8px">WA number tanpa "+" atau spasi. Setelah ditambah, nomor langsung bisa kirim hashtag commands.</div>
  </section>

  <section class="card">
    <h2>4. Current .env (masked)</h2>
    <div class="detail" style="margin-bottom: 12px">
      Read-only viewer. Secret values (password, token, client secret) di-mask. Untuk edit, buka file <code>.env</code> langsung di server lalu restart aplikasi.
    </div>
    <div id="env-list"><div class="detail">Loading…</div></div>
  </section>

  <section class="card">
    <h2>5. Common Setup Commands</h2>
    <div class="detail" style="margin-bottom: 12px">Hover snippet → klik tombol Copy untuk salin ke clipboard.</div>

    <details open>
      <summary>GitHub auth refresh (untuk push workflow file)</summary>
      <div class="snippet-row">
        <pre class="snippet">gh auth refresh -s workflow --hostname github.com</pre>
        <button class="btn copy" data-snippet="gh auth refresh -s workflow --hostname github.com">Copy</button>
      </div>
    </details>

    <details>
      <summary>Restart server (apply .env changes)</summary>
      <div class="snippet-row">
        <pre class="snippet">lsof -ti:3000 | xargs kill && npm run dev</pre>
        <button class="btn copy" data-snippet="lsof -ti:3000 | xargs kill && npm run dev">Copy</button>
      </div>
    </details>

    <details>
      <summary>Backup database</summary>
      <div class="snippet-row">
        <pre class="snippet">PGPASSWORD='WRG@CRM2026!' pg_dump -U wrg_admin -h localhost wrg_crm > backup-$(date +%Y%m%d-%H%M).sql</pre>
        <button class="btn copy" data-snippet="PGPASSWORD='WRG@CRM2026!' pg_dump -U wrg_admin -h localhost wrg_crm > backup-$(date +%Y%m%d-%H%M).sql">Copy</button>
      </div>
    </details>

    <details>
      <summary>Reset DB (drop + reapply + reseed)</summary>
      <div class="snippet-row">
        <pre class="snippet">npm run db:reset</pre>
        <button class="btn copy" data-snippet="npm run db:reset">Copy</button>
      </div>
      <div class="detail" style="margin-top: 6px">⚠️ Ini hapus SEMUA data dan re-seed. Untuk produksi jangan dipakai.</div>
    </details>

    <details>
      <summary>Bulk import 29 AM dari CSV</summary>
      <div class="snippet-row">
        <pre class="snippet">PGPASSWORD='WRG@CRM2026!' psql -U wrg_admin -h localhost -d wrg_crm \\
  -c "\\copy master_user(wa_number, nama_am, area, role) FROM 'ams.csv' CSV HEADER"</pre>
        <button class="btn copy" data-snippet="PGPASSWORD='WRG@CRM2026!' psql -U wrg_admin -h localhost -d wrg_crm -c \"\\copy master_user(wa_number, nama_am, area, role) FROM 'ams.csv' CSV HEADER\"">Copy</button>
      </div>
      <div class="detail" style="margin-top: 6px">CSV header: <code>wa_number,nama_am,area,role</code></div>
    </details>

    <details>
      <summary>Generate strong DASHBOARD_TOKEN</summary>
      <div class="snippet-row">
        <pre class="snippet">node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"</pre>
        <button class="btn copy" data-snippet="node -e &quot;console.log(require('crypto').randomBytes(32).toString('hex'))&quot;">Copy</button>
      </div>
    </details>

    <details>
      <summary>Tail server log (kalau pakai pm2/systemd)</summary>
      <div class="snippet-row">
        <pre class="snippet">tail -f /var/log/wrg-crm.log | grep -E 'error|fail|alert'</pre>
        <button class="btn copy" data-snippet="tail -f /var/log/wrg-crm.log | grep -E 'error|fail|alert'">Copy</button>
      </div>
    </details>
  </section>
</main>

<div class="toast" id="toast"></div>

<script>
const params = new URLSearchParams(location.search);
const TOKEN = params.get('token') || '';

function api(path, opts = {}) {
  const headers = TOKEN ? { authorization: 'Bearer ' + TOKEN } : {};
  if (opts.body) headers['content-type'] = 'application/json';
  return fetch(path, { ...opts, headers, credentials: 'same-origin' })
    .then(r => r.json().then(j => ({ ok: r.ok, body: j })));
}

function toast(msg, ok = true) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.className = 'toast show ' + (ok ? 'ok' : 'err');
  setTimeout(() => { el.classList.remove('show'); }, 2800);
}

function dotFor(ok) {
  if (ok === true) return 'ok';
  if (ok === false) return 'err';
  return 'idle';
}

async function loadStatus() {
  const { body } = await api('/api/setup/status');
  const html = body.rows.map(r =>
    '<div class="row"><span class="dot ' + dotFor(r.ok) + '"></span>' +
    '<span class="label">' + r.label + '</span>' +
    '<span class="detail">' + r.detail + '</span></div>'
  ).join('');
  document.getElementById('status-list').innerHTML = html;
}

async function loadUsers() {
  const { body } = await api('/api/setup/users');
  const tbody = document.querySelector('#user-table tbody');
  if (!body.rows.length) {
    tbody.innerHTML = '<tr><td colspan="8" class="detail">Belum ada user.</td></tr>';
    return;
  }
  tbody.innerHTML = body.rows.map(u => {
    const last = u.last_activity_at
      ? new Date(u.last_activity_at).toLocaleString('id-ID', { hour12: false, timeZone: 'Asia/Jakarta' })
      : '—';
    const aktifPill = u.aktif
      ? '<span class="pill green">aktif</span>'
      : '<span class="pill grey">non-aktif</span>';
    return '<tr>' +
      '<td>' + u.nama_am + '</td>' +
      '<td><code>' + u.wa_number + '</code></td>' +
      '<td>' + (u.area || '—') + '</td>' +
      '<td>' + u.role + '</td>' +
      '<td>' + aktifPill + '</td>' +
      '<td>' + u.visits_30d + '</td>' +
      '<td>' + last + '</td>' +
      '<td><button class="btn" data-toggle="' + u.id + '" data-aktif="' + (!u.aktif) + '">' +
        (u.aktif ? 'Disable' : 'Enable') + '</button></td>' +
    '</tr>';
  }).join('');
  document.querySelectorAll('[data-toggle]').forEach(btn => {
    btn.addEventListener('click', async () => {
      const id = btn.dataset.toggle;
      const aktif = btn.dataset.aktif === 'true';
      const { ok, body } = await api('/api/setup/users/' + id, {
        method: 'PATCH',
        body: JSON.stringify({ aktif }),
      });
      toast(ok ? 'Updated' : 'Error: ' + (body.error || 'unknown'), ok);
      loadUsers();
    });
  });
}

async function loadEnv() {
  const { body } = await api('/api/setup/env');
  if (!body.sections || !body.sections.length) {
    document.getElementById('env-list').innerHTML = '<div class="detail">.env tidak bisa dibaca</div>';
    return;
  }
  const html = body.sections.map(s => {
    const entries = s.entries.map(e => {
      const cls = e.masked ? 'masked' : (e.value === '(kosong)' ? 'empty' : '');
      const comment = e.comment ? '<div class="section-comment">// ' + e.comment + '</div>' : '';
      return comment + '<div class="env-entry">' +
        '<div class="env-key">' + e.key + '</div>' +
        '<div class="env-val ' + cls + '">' + e.value + '</div>' +
      '</div>';
    }).join('');
    return '<details ' + (s.entries.length < 6 ? 'open' : '') + '>' +
      '<summary><b>' + s.title + '</b> (' + s.entries.length + ' keys)</summary>' +
      '<div style="padding: 8px 0 0 12px">' + entries + '</div>' +
    '</details>';
  }).join('');
  document.getElementById('env-list').innerHTML = html;
}

document.getElementById('add-user-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const fd = new FormData(e.target);
  const input = Object.fromEntries(fd.entries());
  const { ok, body } = await api('/api/setup/users', {
    method: 'POST',
    body: JSON.stringify(input),
  });
  if (ok) {
    toast('Added: ' + body.row.nama_am, true);
    e.target.reset();
    loadUsers();
  } else {
    toast('Error: ' + (body.error || 'unknown'), false);
  }
});

document.querySelectorAll('[data-test]').forEach(btn => {
  btn.addEventListener('click', async () => {
    const kind = btn.dataset.test;
    btn.disabled = true;
    btn.textContent = 'Running…';
    const { body } = await api('/api/setup/test/' + kind, { method: 'POST' });
    btn.disabled = false;
    btn.textContent = kind === 'oauth' ? 'Verify' : 'Test ' + (kind === 'wa' ? 'send' : kind === 'alert' ? 'alert' : 'email');
    const out = document.getElementById('test-output');
    out.textContent = JSON.stringify(body, null, 2);
    document.getElementById('test-result').style.display = 'block';
    toast(body.ok ? (kind + ': ' + body.detail) : ('FAIL: ' + body.detail), body.ok);
  });
});

document.querySelectorAll('.copy').forEach(btn => {
  btn.addEventListener('click', async () => {
    const text = btn.dataset.snippet;
    try {
      await navigator.clipboard.writeText(text);
      toast('Copied!', true);
    } catch {
      toast('Copy failed (browser blocked clipboard)', false);
    }
  });
});

loadStatus();
loadUsers();
loadEnv();
</script>
</body>
</html>`;
