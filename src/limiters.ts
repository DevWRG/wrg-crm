import { config } from './config.js';
import { FixedWindowLimiter } from './util/ratelimit.js';

const ONE_MIN_MS = 60_000;

/** Per-WA-number limiter — guards individual AM accounts from runaway. */
export const perWaLimiter = new FixedWindowLimiter(config.rateLimit.perWaPerMin, ONE_MIN_MS);

/** Global per-IP limiter — guards the gateway connection itself. */
export const globalLimiter = new FixedWindowLimiter(config.rateLimit.globalPerMin, ONE_MIN_MS);

const exemptSet = new Set(config.rateLimit.exemptWa);
export function isExempt(wa: string): boolean {
  return exemptSet.has(wa);
}

/** Sweep both limiters; call from a low-frequency timer. */
export function sweepLimiters(): { perWa: number; global: number } {
  return { perWa: perWaLimiter.sweep(), global: globalLimiter.sweep() };
}
