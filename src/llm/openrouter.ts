/**
 * Generic OpenRouter chat completion client.
 *
 * OpenRouter (https://openrouter.ai) adalah aggregator LLM — satu API key
 * bisa akses Claude / GPT / Llama / Gemini / dll. Format request kompatibel
 * dengan OpenAI Chat Completions API.
 *
 * Semua call ke LLM lewat sini supaya:
 *   1. Timeout + error handling konsisten.
 *   2. Fallback graceful kalau API down — caller dapat null, bukan throw.
 *   3. Logging seragam (untuk cost tracking nanti).
 */

import { config } from '../config.js';

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export interface CompletionOpts {
  messages: ChatMessage[];
  model?: string;
  temperature?: number;
  maxTokens?: number;
  /** Custom timeout (default dari config). */
  timeoutMs?: number;
}

export interface CompletionResult {
  ok: boolean;
  text: string;
  model: string;
  usage?: {
    prompt_tokens: number;
    completion_tokens: number;
    total_tokens: number;
  };
  error?: string;
  /** Latensi end-to-end dari Date.now(). */
  latencyMs: number;
}

export function isConfigured(): boolean {
  return Boolean(config.llm.apiKey);
}

export async function complete(opts: CompletionOpts): Promise<CompletionResult> {
  const start = Date.now();
  if (!config.llm.apiKey) {
    return {
      ok: false,
      text: '',
      model: opts.model ?? config.llm.model,
      error: 'OPENROUTER_API_KEY not configured',
      latencyMs: 0,
    };
  }

  const model = opts.model ?? config.llm.model;
  const timeoutMs = opts.timeoutMs ?? config.llm.timeoutMs;
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);

  try {
    const res = await fetch(`${config.llm.baseUrl}/chat/completions`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${config.llm.apiKey}`,
        'HTTP-Referer': config.llm.referer,
        'X-Title': config.llm.appTitle,
      },
      body: JSON.stringify({
        model,
        messages: opts.messages,
        temperature: opts.temperature ?? 0.4,
        max_tokens: opts.maxTokens ?? 400,
      }),
      signal: ctrl.signal,
    });
    const latencyMs = Date.now() - start;
    if (!res.ok) {
      const errText = await res.text().catch(() => '');
      return {
        ok: false,
        text: '',
        model,
        error: `HTTP ${res.status} ${errText.slice(0, 200)}`,
        latencyMs,
      };
    }
    const j = (await res.json()) as {
      choices: Array<{ message: { content: string } }>;
      usage?: { prompt_tokens: number; completion_tokens: number; total_tokens: number };
    };
    const text = j.choices?.[0]?.message?.content?.trim() ?? '';
    return { ok: true, text, model, usage: j.usage, latencyMs };
  } catch (err) {
    return {
      ok: false,
      text: '',
      model,
      error: (err as Error).message,
      latencyMs: Date.now() - start,
    };
  } finally {
    clearTimeout(t);
  }
}

/** Convenience: send a single user prompt with optional system instruction. */
export async function ask(opts: {
  system?: string;
  user: string;
  model?: string;
  temperature?: number;
  maxTokens?: number;
}): Promise<CompletionResult> {
  const messages: ChatMessage[] = [];
  if (opts.system) messages.push({ role: 'system', content: opts.system });
  messages.push({ role: 'user', content: opts.user });
  return complete({
    messages,
    model: opts.model,
    temperature: opts.temperature,
    maxTokens: opts.maxTokens,
  });
}

/**
 * Ask + parse JSON. Strips ```json fences kalau LLM bandel. Return null
 * di json kalau parse gagal — caller decide what to do.
 */
export async function askJson<T = unknown>(opts: {
  system?: string;
  user: string;
  model?: string;
  temperature?: number;
  maxTokens?: number;
}): Promise<CompletionResult & { json: T | null }> {
  const r = await ask(opts);
  if (!r.ok) return { ...r, json: null };
  let raw = r.text.trim();
  // Strip ```json ... ``` fences if present
  const fence = raw.match(/```(?:json)?\s*([\s\S]*?)\s*```/);
  if (fence) raw = fence[1].trim();
  try {
    const json = JSON.parse(raw) as T;
    return { ...r, json };
  } catch {
    return { ...r, json: null };
  }
}
