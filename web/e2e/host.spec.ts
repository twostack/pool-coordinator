import { expect, test, type Page } from '@playwright/test';
import { fakeApi } from './fake-api';

// A host page (scripts/host-fixture.mjs) that installs the packed
// `pool-elements`, themes the elements with its own values and feeds them
// from /api/testnet, as the edge site does. Skipped when POOL_SITE points
// the run at a proxy instead.
test.skip(!!process.env.POOL_SITE, 'the host fixture runs only against the local build');

const host = 'http://127.0.0.1:4174/';

/** Every element under [root], shadow roots included. */
const deep = (page: Page, selector: string) =>
  page.evaluate((sel) => {
    const found: string[] = [];
    const walk = (root: Document | ShadowRoot) => {
      for (const el of root.querySelectorAll('*')) {
        if (el.matches(sel)) found.push(`${el.tagName} ${el.getAttributeNames().join(" ")}`);
        if (el.shadowRoot) walk(el.shadowRoot);
      }
    };
    walk(document);
    return found;
  }, selector);

test('The package is the release\'s: the elements and the feed', async ({ page }) => {
  await fakeApi(page, { base: '/api/testnet' });
  await page.goto(host);
  const defined = await page.evaluate(() =>
    ['pool-live-card', 'pool-round-card', 'pool-stats', 'pool-chart', 'pool-rounds', 'pool-dashboard'].filter((t) => customElements.get(t) !== undefined),
  );
  expect(defined).toHaveLength(6);
  const names = await page.evaluate(() => (window as unknown as { poolExports: string[] }).poolExports);
  for (const n of ['PoolChart', 'PoolDashboard', 'PoolFeed', 'PoolLiveCard', 'PoolRoundCard', 'PoolRounds', 'PoolStats', 'browserDeps']) expect(names).toContain(n);
});

test('A different API base: the embedded elements ask only under /api/testnet/', async ({ page }) => {
  const asked: string[] = [];
  const stray: string[] = [];
  page.on('request', (r) => {
    const u = new URL(r.url());
    if (u.pathname.startsWith('/api') && !u.pathname.startsWith('/api/testnet/')) stray.push(u.pathname);
  });
  await fakeApi(page, { base: '/api/testnet', asked });
  await page.goto(host);
  await expect(page.locator('pool-round-card')).toHaveCount(20);
  expect(asked.length).toBeGreaterThan(3);
  expect(asked.some((p) => p.startsWith('/api/testnet/events'))).toBe(true);
  expect(stray).toEqual([]);
});

test('Themed by the host: colours, fonts and radius are the host\'s', async ({ page }) => {
  await fakeApi(page, { base: '/api/testnet' });
  await page.goto(host);
  await expect(page.locator('pool-stats dd').first()).toBeVisible();
  const tile = page.locator('pool-stats div').first();
  expect(await tile.evaluate((el) => getComputedStyle(el).backgroundColor)).toBe('rgb(244, 246, 241)');
  expect(await tile.evaluate((el) => getComputedStyle(el).borderTopLeftRadius)).toBe('4px');
  expect(await page.locator('pool-stats dt').first().evaluate((el) => getComputedStyle(el).color)).toBe('rgb(88, 102, 108)');
  expect(await page.locator('pool-stats a').first().evaluate((el) => getComputedStyle(el).color)).toBe('rgb(36, 95, 99)');
  expect(await page.locator('pool-stats .txid').first().evaluate((el) => getComputedStyle(el).fontFamily)).toContain('Courier New');
  expect(await page.locator('body > pool-live-card').evaluate((el) => getComputedStyle(el).fontFamily)).toContain('Georgia');
});

test('Markup through an embedded element: shown as text, nothing created', async ({ page }) => {
  const markup = '<img src=x onerror=alert(1)>';
  const dialogs: string[] = [];
  page.on('dialog', (d) => { dialogs.push(d.message()); void d.dismiss(); });
  await fakeApi(page, { base: '/api/testnet', network: markup, issuance: markup });
  await page.goto(host);
  await expect(page.locator('pool-stats')).toContainText(markup);
  expect(await deep(page, '[onerror], img')).toEqual([]);
  expect(dialogs).toEqual([]);
});
