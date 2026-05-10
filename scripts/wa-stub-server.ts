/**
 * Local stub of an OpenClaw-style WA gateway.
 * Pakai untuk verifikasi mode `WA_SEND_MODE=http` tanpa gateway nyata.
 *
 * Run:    npm run gateway:stub
 * Listen: http://localhost:3001
 *
 * Endpoint:
 *   POST /send  → menerima { to, target, text }, log ke stdout,
 *                 balas { messageId: "stub-<id>" } 200.
 *
 * Pakai env STUB_FAIL_RATE (0..1) untuk simulasikan flaky network:
 *   STUB_FAIL_RATE=0.3 npm run gateway:stub  // 30% balas 503
 */

import Fastify from 'fastify';

interface SendBody {
  to: 'group' | 'dm';
  target: string;
  text: string;
}

const port = parseInt(process.env.STUB_PORT || '3001', 10);
const failRate = parseFloat(process.env.STUB_FAIL_RATE || '0');

const app = Fastify({ logger: false });
let counter = 0;

app.get('/health', async () => ({ ok: true, stub: 'wa-gateway' }));

app.post<{ Body: SendBody }>('/send', async (req, reply) => {
  const body = req.body;
  if (!body || typeof body.text !== 'string' || typeof body.target !== 'string') {
    return reply.status(400).send({ error: 'invalid_payload' });
  }
  if (failRate > 0 && Math.random() < failRate) {
    console.log(`[STUB] ✗ simulated 503 to=${body.to} target=${body.target}`);
    return reply.status(503).send({ error: 'simulated_failure' });
  }
  counter += 1;
  const messageId = `stub-${Date.now()}-${counter}`;
  console.log(
    `\n[STUB ← ${req.headers.authorization ? 'AUTH ✓' : 'no-auth'}] ` +
      `${body.to.toUpperCase()} → ${body.target} (msgId=${messageId})\n${body.text}\n`,
  );
  return reply.send({ messageId });
});

app.listen({ port, host: '127.0.0.1' }).then(() => {
  console.log(`WA stub gateway listening on http://127.0.0.1:${port}`);
  console.log(`Set in app .env:  WA_SEND_MODE=http  WA_SEND_URL=http://127.0.0.1:${port}/send`);
  if (failRate > 0) console.log(`Failure rate: ${Math.round(failRate * 100)}%`);
});
