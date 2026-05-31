/**
 * 2026 Shell renderer.
 *
 * Each page provides:
 *   <body data-active="dashboard" data-crumbs="Workspace | Dashboard">
 *     <div class="shell">
 *       <div data-shell-sidebar></div>
 *       <div class="main">
 *         <div data-shell-topbar></div>
 *         <main class="content"> ...page content... </main>
 *         <div data-shell-footer></div>
 *       </div>
 *     </div>
 *   </body>
 *
 * mountShell() fills the three placeholder divs with the shared chrome,
 * marking the active sidebar item and writing the breadcrumbs.
 *
 * NAV is the single source of truth — adding a page is one entry here.
 */

export const NAV = [
  {
    label: 'HR',
    items: [
      { key: 'dashboard', text: 'Plan & Report', href: 'index.html',
        icon: '<path d="M3 3h7v7H3z"/><path d="M14 3h7v7h-7z"/><path d="M14 14h7v7h-7z"/><path d="M3 14h7v7H3z"/>' },
      { key: 'holidays', text: 'Holidays', href: 'holidays.html',
        icon: '<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/>' },
      { key: 'leave', text: 'Manage Leave', href: 'leave.html',
        icon: '<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/><path d="M9 16l2 2 4-4"/>' },
    ],
  },
  {
    label: 'Admin',
    items: [
      { key: 'users', text: 'Users', href: 'users.html',
        icon: '<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4.4 3.6-8 8-8s8 3.6 8 8"/>' },
    ],
  },
  {
    label: 'Adminator Demo (reference)',
    items: [
      { key: 'charts', text: 'Charts', href: 'charts.html',
        icon: '<path d="M3 20V4M7 20v-6M11 20v-10M15 20v-4M19 20V8"/>' },
      { key: 'forms', text: 'Forms', href: 'forms.html',
        icon: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 10h10M7 14h7"/>' },
      { key: 'tables', text: 'Tables',
        icon: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M3 16h18M9 4v16"/>',
        children: [
          { key: 'basic-table', text: 'Basic Table', href: 'basic-table.html' },
          { key: 'datatable',   text: 'Data Table',  href: 'datatable.html' },
        ],
      },
    ],
  },
];

const BRAND_LOGO = `<svg viewBox="0 0 36 36" xmlns="http://www.w3.org/2000/svg">
  <path fill="#ffffff" d="M14.747 9.125c.527-1.426 1.736-2.573 3.317-2.573c1.643 0 2.792 1.085 3.318 2.573l6.077 16.867c.186.496.248.931.248 1.147c0 1.209-.992 2.046-2.139 2.046c-1.303 0-1.954-.682-2.264-1.611l-.931-2.915h-8.62l-.93 2.884c-.31.961-.961 1.642-2.232 1.642c-1.24 0-2.294-.93-2.294-2.17c0-.496.155-.868.217-1.023l6.233-16.867zm.34 11.256h5.891l-2.883-8.992h-.062l-2.946 8.992z"/>
</svg>`;

const CHEV = '<svg class="chev" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="m9 18 6-6-6-6"/></svg>';

function renderNavLink(item, activeKey) {
  const active = item.key === activeKey ? ' is-active' : '';
  const badge = item.badge
    ? `<span class="nav-badge ${item.badge.kind}">${item.badge.text}</span>`
    : '';
  const external = /^https?:\/\//.test(item.href) ? ' target="_blank" rel="noopener noreferrer"' : '';
  return `
    <a class="nav-link${active}" href="${item.href}"${external}>
      <svg viewBox="0 0 24 24">${item.icon}</svg>
      <span>${item.text}</span>
      ${badge}
    </a>`;
}

function renderNavGroup(item, activeKey) {
  const open = item.children.some((c) => c.key === activeKey) ? ' is-open' : '';
  const submenu = item.children
    .map((c) => `<a href="${c.href}">${c.text}</a>`)
    .join('');
  return `
    <div class="nav-item-group${open}" data-nav-group>
      <a class="nav-link" href="javascript:void(0)" data-nav-toggle>
        <svg viewBox="0 0 24 24">${item.icon}</svg>
        <span>${item.text}</span>
        ${CHEV}
      </a>
      <div class="nav-submenu">${submenu}</div>
    </div>`;
}

function renderSection(section, activeKey) {
  const items = section.items.map((item) => (
    item.children ? renderNavGroup(item, activeKey) : renderNavLink(item, activeKey)
  )).join('');
  return `
    <nav class="nav-section">
      <div class="nav-label">${section.label}</div>
      ${items}
    </nav>`;
}

function renderSidebar(activeKey) {
  const sections = NAV.map((s) => renderSection(s, activeKey)).join('');
  return `
    <style>
      [data-theme="dark"] .wrg-brand-light { display: none !important; }
      [data-theme="dark"] .wrg-brand-dark  { display: block !important; }
      [data-theme="light"] .wrg-brand-dark { display: none !important; }
    </style>
    <aside class="d-sidebar">
      <div class="brand" style="padding:12px 16px;">
        <img class="wrg-brand-light" src="assets/static/images/wrg/logo-light.png" alt="Wahana LifeLine" style="max-width:120px; max-height:32px; object-fit:contain;">
        <img class="wrg-brand-dark"  src="assets/static/images/wrg/logo-dark.png"  alt="Wahana LifeLine" style="max-width:120px; max-height:32px; object-fit:contain; display:none;">
      </div>
      ${sections}
      <div class="sidebar-footer">
        <div class="workspace">
          <div class="workspace-avatar" id="wrgUserAvatar">—</div>
          <div class="workspace-text">
            <div class="workspace-name" id="wrgUserName">—</div>
            <div class="workspace-role" id="wrgUserRole">—</div>
          </div>
          <svg class="workspace-chev" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
            <path d="m7 9 5-5 5 5"/><path d="m7 15 5 5 5-5"/>
          </svg>
        </div>
      </div>
    </aside>`;
}

function renderCrumbs(crumbsAttr) {
  if (!crumbsAttr) return '';
  const parts = crumbsAttr.split('|').map((p) => p.trim()).filter(Boolean);
  const sep = '<svg class="sep" width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="m9 18 6-6-6-6"/></svg>';
  return parts.map((p, i) => {
    const cls = i === parts.length - 1 ? ' class="current"' : '';
    return `${i > 0 ? sep : ''}<span${cls}>${p}</span>`;
  }).join('');
}

function renderTopbar(crumbsAttr) {
  return `
    <header class="d-topbar">
      <div class="crumbs">
        <button class="hamburger" data-drawer-open aria-label="Open navigation">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/></svg>
        </button>
        ${renderCrumbs(crumbsAttr)}
      </div>
      <div class="topbar-actions">
        <button class="cmd" data-palette-open>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg>
          <span>Search...</span>
          <kbd class="kbd">⌘K</kbd>
        </button>

        <div class="dd-wrap">
          <button class="icon-btn" data-dropdown aria-label="Notifications">
            <svg viewBox="0 0 24 24"><path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/></svg>
            <span class="count danger">3</span>
          </button>
          <div class="dd-menu" role="menu">
            <div class="dd-head">
              <svg viewBox="0 0 24 24"><path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/><path d="M13.73 21a2 2 0 0 1-3.46 0"/></svg>
              Notifications
            </div>
            <div class="dd-list">
              <a class="dd-item" href="#">
                <div class="dd-avatar a1">JD</div>
                <div class="dd-body">
                  <div class="dd-text"><strong>John Doe</strong> liked your <em>post</em></div>
                  <div class="dd-time">5 MIN AGO</div>
                </div>
              </a>
              <a class="dd-item" href="#">
                <div class="dd-avatar a2">MD</div>
                <div class="dd-body">
                  <div class="dd-text"><strong>Moo Doe</strong> liked your <em>cover image</em></div>
                  <div class="dd-time">7 MIN AGO</div>
                </div>
              </a>
              <a class="dd-item" href="#">
                <div class="dd-avatar a3">LD</div>
                <div class="dd-body">
                  <div class="dd-text"><strong>Lee Doe</strong> commented on your <em>video</em></div>
                  <div class="dd-time">10 MIN AGO</div>
                </div>
              </a>
            </div>
            <a class="dd-footer" href="#">View all notifications →</a>
          </div>
        </div>

        <div class="dd-wrap">
          <button class="icon-btn" data-dropdown aria-label="Messages">
            <svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/></svg>
            <span class="count info">3</span>
          </button>
          <div class="dd-menu" role="menu">
            <div class="dd-head">
              <svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/></svg>
              Messages
            </div>
            <div class="dd-list">
              <a class="dd-item" href="#">
                <div class="dd-avatar a1">JD</div>
                <div class="dd-body">
                  <div class="dd-row-head"><strong>John Doe</strong><span class="dd-time">5 MIN</span></div>
                  <div class="dd-preview">Want to create your own customized data generator for your app…</div>
                </div>
              </a>
              <a class="dd-item" href="#">
                <div class="dd-avatar a2">MD</div>
                <div class="dd-body">
                  <div class="dd-row-head"><strong>Moo Doe</strong><span class="dd-time">15 MIN</span></div>
                  <div class="dd-preview">Want to create your own customized data generator for your app…</div>
                </div>
              </a>
              <a class="dd-item" href="#">
                <div class="dd-avatar a3">LD</div>
                <div class="dd-body">
                  <div class="dd-row-head"><strong>Lee Doe</strong><span class="dd-time">25 MIN</span></div>
                  <div class="dd-preview">Want to create your own customized data generator for your app…</div>
                </div>
              </a>
            </div>
            <a class="dd-footer" href="#">View all messages →</a>
          </div>
        </div>

        <button class="icon-btn" id="themeToggle" aria-label="Toggle theme"></button>

        <div class="dd-wrap">
          <div class="avatar" id="wrgTopAvatar" data-dropdown tabindex="0" role="button" aria-label="Account menu">—</div>
          <div class="dd-menu dd-profile" role="menu">
            <div class="dd-profile-head">
              <div class="dd-profile-name" id="wrgTopName">—</div>
              <div class="dd-profile-email" id="wrgTopRole">—</div>
            </div>
            <a class="dd-menu-item" href="#" id="wrgChangePw">
              <svg viewBox="0 0 24 24"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>
              Ganti password
            </a>
            <a class="dd-menu-item" href="users.html" id="wrgUsersLink">
              <svg viewBox="0 0 24 24"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/></svg>
              Users
            </a>
            <div class="dd-divider"></div>
            <a class="dd-menu-item danger" href="#" id="wrgLogoutDropdown">
              <svg viewBox="0 0 24 24"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg>
              Logout
            </a>
          </div>
        </div>
      </div>
    </header>`;
}

function renderFooter() {
  return `
    <footer class="d-footer">
      <div>© 2026 · Designed by <a href="https://colorlib.com" target="_blank" rel="nofollow noopener noreferrer">Colorlib</a></div>
      <div class="d-footer-meta">
        <span>v4.1.5</span>
        <span>preview build</span>
      </div>
    </footer>`;
}

export function mountShell() {
  const body = document.body;
  const activeKey = body.getAttribute('data-active') || '';
  const crumbs = body.getAttribute('data-crumbs') || '';

  const sidebarHost = document.querySelector('[data-shell-sidebar]');
  const topbarHost  = document.querySelector('[data-shell-topbar]');
  const footerHost  = document.querySelector('[data-shell-footer]');

  if (sidebarHost) sidebarHost.outerHTML = renderSidebar(activeKey);
  if (topbarHost)  topbarHost.outerHTML  = renderTopbar(crumbs);
  if (footerHost)  footerHost.outerHTML  = renderFooter();

  // Auth bootstrap — WRG pages (Adminator demo pages bypass).
  // Skip on login page itself. Check /api/auth/me, redirect to login if 401.
  const isWrgPage = ['dashboard', 'leave', 'holidays', 'users', 'drilldown'].includes(activeKey);
  if (isWrgPage) {
    fetch('/api/auth/me')
      .then((r) => r.ok ? r.json() : null)
      .then((data) => {
        if (!data) {
          location.href = '/login.html?next=' + encodeURIComponent(location.pathname);
          return;
        }
        // Populate sidebar footer + topbar avatar dropdown (replaces hardcoded John Doe)
        const user = data.user;
        const displayName = user.panggilan || user.nama || '?';
        const initials = displayName.replace(/[^A-Za-z]/g, '').slice(0, 2).toUpperCase() || '?';
        const roleLabel = user.role + (user.is_admin ? ' · admin' : '');
        const fills = {
          wrgUserAvatar: initials, wrgUserName: displayName, wrgUserRole: roleLabel,
          wrgTopAvatar:  initials, wrgTopName:  displayName, wrgTopRole:  roleLabel,
        };
        Object.entries(fills).forEach(([id, t]) => {
          const el = document.getElementById(id);
          if (el) el.textContent = t;
        });

        // Wire Logout (di dropdown topbar)
        const logoutLink = document.getElementById('wrgLogoutDropdown');
        if (logoutLink) {
          logoutLink.addEventListener('click', async (e) => {
            e.preventDefault();
            await fetch('/api/auth/logout', { method: 'POST' });
            location.href = '/login.html';
          });
        }

        // Change-password placeholder (TODO Phase 5e — wire ke endpoint nanti)
        const cpLink = document.getElementById('wrgChangePw');
        if (cpLink) cpLink.addEventListener('click', (e) => {
          e.preventDefault();
          alert('Ganti password belum di-implement. Hubungi admin untuk reset.');
        });

        // Hide admin-only sidebar/dropdown links if regular user
        if (!user.is_admin) {
          document.querySelectorAll('a[href*="leave.html"], a[href*="holidays.html"], a[href*="users.html"]').forEach((a) => {
            a.style.display = 'none';
          });
        }
      })
      .catch(() => {
        location.href = '/login.html?next=' + encodeURIComponent(location.pathname);
      });
  }
}
