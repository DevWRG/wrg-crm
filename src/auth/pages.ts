/** Login page HTML — minimal, no deps. */

import { isConfigured } from './google.js';

export function renderLoginPage(returnTo?: string): string {
  const rt = returnTo ? `?returnTo=${encodeURIComponent(returnTo)}` : '';
  const googleEnabled = isConfigured();

  return `<!DOCTYPE html>
<html lang="id"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Login — WRG CRM</title>
<style>
  * { box-sizing: border-box; }
  body { background: #0e1116; color: #e6edf3; margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    min-height: 100vh; display: flex; align-items: center; justify-content: center;
    font-size: 14px; }
  .card { background: #161b22; border: 1px solid #2a313c; border-radius: 12px;
    padding: 40px; min-width: 360px; max-width: 90vw; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  h1 .accent { color: #f78166; }
  p.sub { color: #8b949e; margin: 0 0 24px; font-size: 13px; }
  a.btn { display: flex; align-items: center; justify-content: center; gap: 10px;
    background: white; color: #1a1a1a; padding: 10px 16px; border-radius: 6px;
    text-decoration: none; font-weight: 500; font-size: 14px;
    transition: transform 0.05s; }
  a.btn:hover { transform: translateY(-1px); }
  a.btn:active { transform: translateY(0); }
  .disabled { background: #2a313c; color: #8b949e; cursor: not-allowed; }
  .footer { color: #8b949e; font-size: 12px; margin-top: 24px; text-align: center; }
  .footer code { background: #2a313c; padding: 2px 6px; border-radius: 3px; }
</style></head><body>
<div class="card">
  <h1>WRG CRM <span class="accent">Dashboard</span></h1>
  <p class="sub">Login dengan akun Google internal.</p>
  ${googleEnabled
    ? `<a class="btn" href="/auth/google${rt}">
        <svg width="18" height="18" viewBox="0 0 18 18" xmlns="http://www.w3.org/2000/svg">
          <path d="M16.51 8.18c0-.46-.04-.92-.13-1.36H9v2.74h4.21c-.18.98-.74 1.81-1.58 2.36v1.96h2.55c1.49-1.37 2.33-3.39 2.33-5.7z" fill="#4285F4"/>
          <path d="M9 17c2.13 0 3.92-.71 5.22-1.92l-2.55-1.96c-.71.47-1.61.75-2.67.75-2.05 0-3.79-1.39-4.41-3.25H1.95v2.04C3.24 15.32 5.93 17 9 17z" fill="#34A853"/>
          <path d="M4.59 10.62c-.16-.47-.25-.97-.25-1.49s.09-1.02.25-1.49V5.6H1.95C1.34 6.66 1 7.79 1 9c0 1.21.34 2.34.95 3.4l2.64-2.04z" fill="#FBBC05"/>
          <path d="M9 4.13c1.16 0 2.2.4 3.02 1.18l2.27-2.27C13.92 1.79 12.13 1 9 1 5.93 1 3.24 2.68 1.95 5.6l2.64 2.04C5.21 5.78 6.95 4.13 9 4.13z" fill="#EA4335"/>
        </svg>
        Sign in with Google
      </a>`
    : `<a class="btn disabled">Google OAuth not configured</a>
       <p class="footer">Admin: set <code>OAUTH_GOOGLE_CLIENT_ID</code> dan <code>OAUTH_GOOGLE_CLIENT_SECRET</code> di <code>.env</code>.</p>`}
  <p class="footer">Untuk akses API (curl/script): pakai header<br/>
    <code>Authorization: Bearer &lt;DASHBOARD_TOKEN&gt;</code></p>
</div>
</body></html>`;
}
