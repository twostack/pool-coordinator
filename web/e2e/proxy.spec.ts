import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { expect, test } from '@playwright/test';

// Through the proxy, against a real coordinator on localnet: run by
// tool/dashboard_e2e.sh, which sets POOL_SITE to the proxy's origin and
// POOL_E2E_SIGNALS to the folder the coordinator's run watches. The page
// loads before round 1 is submitted, signals `go`, and must show round 1
// mined without a reload.

const site = process.env.POOL_SITE;
const signals = process.env.POOL_E2E_SIGNALS;

test.skip(site === undefined || signals === undefined, 'run by tool/dashboard_e2e.sh');

test('Through the proxy: the page loads, a round mined on localnet appears live, writes are refused', async ({ page, request }) => {
  test.setTimeout(10 * 60_000);
  const blocked: string[] = [];
  page.on('console', (m) => {
    if (/Content Security Policy|Refused to/i.test(m.text())) blocked.push(m.text());
  });
  page.on('pageerror', (e) => blocked.push(String(e)));

  const doc = await page.goto('/');
  const headers = doc?.headers() ?? {};
  expect(headers['content-security-policy']).toContain("default-src 'self'");
  expect(headers['strict-transport-security']).toBeDefined();
  expect(headers['server']).toBeUndefined();

  await expect(page.locator('pool-dashboard h1')).toHaveText('BSV Shielded Pool');
  await expect(page.locator('pool-dashboard .network')).toHaveText('regtest');
  await expect(page.locator('pool-round-card')).toHaveCount(0);
  await expect(page.locator('pool-live-card').last()).toContainText('Round 1');

  // the page is listening: now the run submits round 1
  writeFileSync(join(signals!, 'go'), '');

  // the live card for round 1 may be skipped when a stage lasts less than
  // the publication interval, so it is only reported; the mined card is
  // what must arrive
  let seenLive = false;
  const watch = setInterval(() => {
    void page.locator('pool-live-card', { hasText: 'being built' }).count().then((n) => (seenLive ||= n > 0), () => {});
  }, 250);
  const card = page.locator('pool-round-card').first();
  try {
    await expect(card).toContainText('Round 1', { timeout: 5 * 60_000 });
    await expect(card).toContainText('mined in block', { timeout: 60_000 });
  } finally {
    clearInterval(watch);
  }
  console.log(`  round 1's live card was ${seenLive ? '' : 'not '}seen before it was mined`);
  // regtest has no explorer: txids are text, not links
  await expect(card.locator('span.txid')).toHaveCount(3);
  await expect(page.locator('pool-dashboard .stale')).toHaveCount(0);
  expect(blocked).toEqual([]);

  // writes never reach the coordinator
  for (const method of ['POST', 'PUT', 'DELETE', 'PATCH']) {
    const r = await request.fetch('/api/pool', { method });
    expect(r.status(), method).toBe(405);
    expect(r.headers()['allow']).toBe('GET, HEAD');
  }
  const pool = await request.get('/api/pool');
  expect(pool.status()).toBe(200);
  expect((await pool.json()).v).toBe(1);

  // the rate limit: a burst from one address is cut off at the proxy
  const statuses = await Promise.all(Array.from({ length: 150 }, () => request.get('/api/stats').then((r) => r.status())));
  expect(statuses).toContain(429);
  expect(statuses.filter((s) => s !== 200 && s !== 429)).toEqual([]);

  writeFileSync(join(signals!, 'done'), '');
});
