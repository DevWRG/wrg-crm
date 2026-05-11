import 'dotenv/config';

export const config = {
  port: parseInt(process.env.PORT || '3000', 10),
  tz: process.env.TZ || 'Asia/Jakarta',
  pg: {
    host: process.env.PGHOST || 'localhost',
    port: parseInt(process.env.PGPORT || '5432', 10),
    database: process.env.PGDATABASE || 'wrg_crm',
    user: process.env.PGUSER || 'wrg_admin',
    password: process.env.PGPASSWORD || '',
  },
  wa: {
    sendMode: (process.env.WA_SEND_MODE || 'mock') as 'mock' | 'http',
    sendUrl: process.env.WA_SEND_URL || '',
    sendToken: process.env.WA_SEND_TOKEN || '',
    timeoutMs: parseInt(process.env.WA_HTTP_TIMEOUT_MS || '10000', 10),
    retries: parseInt(process.env.WA_HTTP_RETRIES || '2', 10),
    groupId: process.env.WA_GROUP_ID || 'wrg-sales-command-center',
    hodGroupId: process.env.WA_HOD_GROUP_ID || 'wrg-hod',
  },
  rateLimit: {
    perWaPerMin: parseInt(process.env.RATE_LIMIT_PER_WA_PER_MIN || '20', 10),
    globalPerMin: parseInt(process.env.RATE_LIMIT_GLOBAL_PER_MIN || '600', 10),
    exemptWa: (process.env.RATE_LIMIT_EXEMPT_WA || '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
  },
  resend: {
    maxAttempts: parseInt(process.env.RESEND_MAX_ATTEMPTS || '3', 10),
    backoffMin: parseInt(process.env.RESEND_BACKOFF_MIN || '5', 10),
    ttlHours: parseInt(process.env.RESEND_TTL_HOURS || '24', 10),
    batchSize: parseInt(process.env.RESEND_BATCH_SIZE || '20', 10),
  },
  dashboard: {
    token: process.env.DASHBOARD_TOKEN || '',
  },
  llm: {
    apiKey: process.env.OPENROUTER_API_KEY || '',
    model: process.env.OPENROUTER_MODEL || 'openai/gpt-4o-mini',
    baseUrl: process.env.OPENROUTER_BASE_URL || 'https://openrouter.ai/api/v1',
    timeoutMs: parseInt(process.env.OPENROUTER_TIMEOUT_MS || '10000', 10),
    /** Optional referer + title untuk OpenRouter analytics. */
    referer: process.env.OPENROUTER_REFERER || 'https://github.com/DevWRG/wrg-crm',
    appTitle: process.env.OPENROUTER_APP_TITLE || 'WRG CRM',
    /** Aktifkan classifier untuk pesan non-hashtag (freeform → suggested hashtag). */
    freeformParserEnabled: process.env.LLM_FREEFORM_PARSER_ENABLED === 'true',
    /** Confidence threshold untuk fire suggestion (default 0.65). */
    freeformConfidence: parseFloat(process.env.LLM_FREEFORM_CONFIDENCE || '0.65'),
  },
  auth: {
    googleClientId: process.env.OAUTH_GOOGLE_CLIENT_ID || '',
    googleClientSecret: process.env.OAUTH_GOOGLE_CLIENT_SECRET || '',
    /** Domain HD restriction (Google Workspace). E.g. "wahanalifeline.co.id". */
    googleHostedDomain: process.env.OAUTH_GOOGLE_HD || '',
    /** Optional email allowlist (comma-separated). Empty = allow anyone in HD. */
    emailAllowlist: (process.env.OAUTH_EMAIL_ALLOWLIST || '')
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean),
    /** Public-facing base URL (untuk OAuth callback redirect_uri). */
    baseUrl: process.env.OAUTH_BASE_URL || 'http://localhost:3000',
    sessionTtlDays: parseInt(process.env.SESSION_TTL_DAYS || '7', 10),
  },
  alerts: {
    webhookUrl: process.env.ALERT_WEBHOOK_URL || '',
    webhookTimeoutMs: parseInt(process.env.ALERT_WEBHOOK_TIMEOUT_MS || '5000', 10),
    waNumber: process.env.ALERT_WA_NUMBER || '',
    debounceMin: parseInt(process.env.ALERT_DEBOUNCE_MIN || '30', 10),
    escalateAfterMin: parseInt(process.env.ALERT_ESCALATE_AFTER_MIN || '15', 10),
  },
  email: {
    enabled: process.env.EMAIL_ENABLED === 'true',
    smtpHost: process.env.SMTP_HOST || '',
    smtpPort: parseInt(process.env.SMTP_PORT || '587', 10),
    smtpUser: process.env.SMTP_USER || '',
    smtpPass: process.env.SMTP_PASS || '',
    smtpSecure: process.env.SMTP_SECURE === 'true',
    from: process.env.EMAIL_FROM || 'WRG CRM <noreply@localhost>',
    hodRecipients: (process.env.EMAIL_HOD_RECIPIENTS || '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
    digestCron: process.env.EMAIL_DIGEST_CRON || '0 8 * * 1',
  },
};
