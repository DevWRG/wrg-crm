/**
 * In-memory fixed-window rate limiter.
 *
 * Cocok untuk single-instance deployment. Untuk multi-instance, swap
 * implementasi-nya dengan Redis-backed (key-prefixed INCR + EXPIRE).
 */

export interface RateLimitResult {
  allowed: boolean;
  retryAfterSec: number;
  remaining: number;
  limit: number;
}

interface Bucket {
  count: number;
  resetAt: number; // ms epoch
}

export class FixedWindowLimiter {
  private buckets = new Map<string, Bucket>();

  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
  ) {}

  check(key: string): RateLimitResult {
    const now = Date.now();
    let b = this.buckets.get(key);
    if (!b || b.resetAt <= now) {
      b = { count: 0, resetAt: now + this.windowMs };
      this.buckets.set(key, b);
    }
    if (b.count >= this.limit) {
      return {
        allowed: false,
        retryAfterSec: Math.max(1, Math.ceil((b.resetAt - now) / 1000)),
        remaining: 0,
        limit: this.limit,
      };
    }
    b.count += 1;
    return {
      allowed: true,
      retryAfterSec: 0,
      remaining: this.limit - b.count,
      limit: this.limit,
    };
  }

  reset(key?: string): void {
    if (key === undefined) this.buckets.clear();
    else this.buckets.delete(key);
  }

  sweep(): number {
    const now = Date.now();
    let removed = 0;
    for (const [k, b] of this.buckets) {
      if (b.resetAt <= now) {
        this.buckets.delete(k);
        removed += 1;
      }
    }
    return removed;
  }

  size(): number {
    return this.buckets.size;
  }
}
