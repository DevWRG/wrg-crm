/**
 * Local stub Slack-compatible webhook. Pakai untuk verifikasi
 * ALERT_WEBHOOK_URL wiring tanpa Slack beneran.
 *
 *   npm run gateway:stub  (untuk WA send-mode http)
 *   tsx scripts/alert-stub.ts  (alert webhook)
 */

import Fastify from 'fastify';

const port = parseInt(process.env.ALERT_STUB_PORT || '3001', 10);
const app = Fastify({ logger: false });

app.post('/alert', async (req, reply) => {
  // eslint-disable-next-line no-console
  console.log('\n[ALERT-STUB ←]', JSON.stringify(req.body, null, 2));
  return reply.send({ ok: true, received_at: new Date().toISOString() });
});

app.listen({ port, host: '127.0.0.1' }).then(() => {
  // eslint-disable-next-line no-console
  console.log(`alert webhook stub listening on http://127.0.0.1:${port}/alert`);
});
