import { randomBytes } from 'node:crypto';
import { config } from '../config.js';

const AUTHORIZE_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const USERINFO_URL = 'https://www.googleapis.com/oauth2/v2/userinfo';

const SCOPES = ['openid', 'email', 'profile'];

export interface GoogleUserInfo {
  id: string;
  email: string;
  verified_email?: boolean;
  name?: string;
  picture?: string;
  hd?: string; // hosted domain (Google Workspace)
}

/** Generate CSRF state nonce. */
export function newState(): string {
  return randomBytes(16).toString('hex');
}

export function isConfigured(): boolean {
  return Boolean(config.auth.googleClientId && config.auth.googleClientSecret);
}

export function buildAuthorizeUrl(state: string, returnTo?: string): string {
  const params = new URLSearchParams({
    client_id: config.auth.googleClientId,
    redirect_uri: `${config.auth.baseUrl}/auth/google/callback`,
    response_type: 'code',
    scope: SCOPES.join(' '),
    state,
    access_type: 'online',
    prompt: 'select_account',
  });
  if (config.auth.googleHostedDomain) {
    params.set('hd', config.auth.googleHostedDomain);
  }
  if (returnTo) {
    // Caller is expected to validate/sanitize returnTo before storing in state.
    params.set('state', `${state}.${encodeURIComponent(returnTo)}`);
  }
  return `${AUTHORIZE_URL}?${params}`;
}

interface TokenResponse {
  access_token: string;
  expires_in: number;
  token_type: string;
  id_token?: string;
  refresh_token?: string;
}

export async function exchangeCode(code: string): Promise<TokenResponse> {
  const body = new URLSearchParams({
    code,
    client_id: config.auth.googleClientId,
    client_secret: config.auth.googleClientSecret,
    redirect_uri: `${config.auth.baseUrl}/auth/google/callback`,
    grant_type: 'authorization_code',
  });
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Token exchange failed: HTTP ${res.status} ${text.slice(0, 200)}`);
  }
  return res.json() as Promise<TokenResponse>;
}

export async function fetchUserInfo(accessToken: string): Promise<GoogleUserInfo> {
  const res = await fetch(USERINFO_URL, {
    headers: { authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) {
    throw new Error(`Userinfo fetch failed: HTTP ${res.status}`);
  }
  return res.json() as Promise<GoogleUserInfo>;
}

/**
 * Cek apakah user diizinkan akses. Return null kalau OK, atau string reason
 * kalau ditolak (untuk audit log).
 */
export function verifyAccess(user: GoogleUserInfo): string | null {
  if (!user.email) return 'no email';
  if (user.verified_email === false) return 'email not verified';

  const email = user.email.toLowerCase();
  const hd = config.auth.googleHostedDomain;
  const allowlist = config.auth.emailAllowlist;

  // Kalau allowlist diset → email harus persis ada di situ.
  if (allowlist.length > 0) {
    if (!allowlist.includes(email)) return 'email not in allowlist';
    return null;
  }

  // Kalau HD diset → user.hd harus match.
  if (hd) {
    if (user.hd !== hd) {
      return `wrong hosted domain (got "${user.hd ?? 'none'}", expected "${hd}")`;
    }
    return null;
  }

  // No HD, no allowlist → siapa pun yang punya akun Google bisa login.
  // Kasih warning di log tapi tetap allow (kalau admin yang setting OAuth
  // tanpa restriction, itu memang choice mereka untuk dev environment).
  return null;
}
