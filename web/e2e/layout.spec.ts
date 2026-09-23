import { expect, test, type Page } from '@playwright/test';

// The built site against a fake API: every /api/ request is answered here,
// so the layout checks need no coordinator.

const txid = (n: number, kind: number) => (n * 16 + kind).toString(16).padStart(64, '0');
const live = { at: 1_790_000_000, assembling: true, closesBy: Math.ceil(Date.now() / 1_000) + 300, rounds: [{ number: 31, stage: 'proving' }] };

function round(n: number) {
  return {
    number: n, y: txid(n, 1), round: txid(n, 2), witness: txid(n, 3), transfers: 3, capacity: 4,
    balance: 100_000 + n, cost: 4_400, buildMs: 9_000, provingMs: 254_000,
    publishedAt: 1_790_000_000 + n * 600, minedHeight: 900_000 + n, minedAt: 1_790_000_030 + n * 600,
  };
}

async function fakeApi(page: Page): Promise<void> {
  await page.route('**/api/**', async (route) => {
    const url = new URL(route.request().url());
    const json = (body: object) => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ v: 1, ...body }) });
    switch (url.pathname) {
      case '/api/pool':
        return json({
          network: 'test', explorer: 'test', plan: 'test', capacity: 4,
          genesis: { issuance: txid(0, 1), witness0: txid(0, 2), slot0: txid(0, 3) },
          tip: 30, balance: 100_030, roundDeadlineSeconds: 600, publishIntervalSeconds: 30, live,
        });
      case '/api/rounds': {
        const before = Number(url.searchParams.get('before') ?? 31);
        const limit = Number(url.searchParams.get('limit') ?? 20);
        const rounds = [];
        for (let n = before - 1; n >= 1 && rounds.length < limit; n--) rounds.push(round(n));
        const last = rounds.at(-1);
        return json({ rounds, next: last && last.number > 1 ? last.number : null });
      }
      case '/api/stats':
        return json({ roundsMined: 30, transfers: 90, tip: 30, medianIntervalSeconds: 600, medianProvingSeconds: 254, meanCost: 4_400, firstPublishedAt: 1_790_000_600 });
      case '/api/series':
        return json({
          metric: url.searchParams.get('metric'), bucket: url.searchParams.get('bucket'),
          points: Array.from({ length: 24 }, (_, i) => ({ t: 1_790_000_000 + i * 3_600, value: (i % 3) + 1 })),
        });
      case '/api/events':
        return route.fulfill({ contentType: 'text/event-stream', body: `event: live\ndata: ${JSON.stringify({ v: 1, ...live })}\n\n` });
      default:
        return route.fulfill({ status: 404, contentType: 'application/json', body: '{"v":1,"error":"not found"}' });
    }
  });
}

const scroller = (page: Page) => page.locator('pool-rounds .scroll');

test.describe('at 360 px', () => {
  test.use({ viewport: { width: 360, height: 740 } });

  test('Narrow viewport: the page fits and only the round scroll scrolls, by keyboard too', async ({ page }) => {
    await fakeApi(page);
    await page.goto('/');
    await expect(page.locator('pool-round-card')).toHaveCount(20);
    await expect(page.locator('pool-live-card')).toHaveCount(2);

    const widths = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, view: window.innerWidth }));
    expect(widths.doc).toBeLessThanOrEqual(widths.view);

    const scroll = scroller(page);
    const box = await scroll.evaluate((el) => ({ scroll: el.scrollWidth, client: el.clientWidth, left: el.scrollLeft }));
    expect(box.scroll).toBeGreaterThan(box.client);
    // pinned to the newest card: the right end is in view
    expect(box.left + box.client).toBeGreaterThanOrEqual(box.scroll - 16);

    await scroll.focus();
    await page.keyboard.press('ArrowLeft');
    await expect.poll(() => scroll.evaluate((el) => el.scrollLeft)).toBeLessThan(box.left);
    const after = await scroll.evaluate((el) => el.scrollLeft);
    await page.keyboard.press('ArrowRight');
    await expect.poll(() => scroll.evaluate((el) => el.scrollLeft)).toBeGreaterThan(after);

    // Home reaches the left end, which pages older rounds in, down to round 1
    await page.keyboard.press('Home');
    await expect.poll(async () => page.locator('pool-round-card').count(), { timeout: 10_000 }).toBe(30);
  });

  test('reduced motion stops the stage animation', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await fakeApi(page);
    await page.goto('/');
    const active = page.locator('pool-live-card li.active');
    await expect(active).toHaveText('proving');
    expect(await active.evaluate((el) => getComputedStyle(el, '::before').animationName)).toBe('none');

    await page.emulateMedia({ reducedMotion: 'no-preference' });
    expect(await active.evaluate((el) => getComputedStyle(el, '::before').animationName)).toBe('pulse');
  });

  test('light and dark themes', async ({ page }) => {
    await fakeApi(page);
    await page.emulateMedia({ colorScheme: 'light' });
    await page.goto('/');
    const bg = () => page.evaluate(() => getComputedStyle(document.body).backgroundColor);
    const light = await bg();
    await page.emulateMedia({ colorScheme: 'dark' });
    const dark = await bg();
    expect(light).toBe('rgb(247, 247, 245)');
    expect(dark).toBe('rgb(17, 19, 22)');
  });
});
