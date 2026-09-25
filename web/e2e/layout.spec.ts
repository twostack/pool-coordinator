import { expect, test, type Page } from '@playwright/test';
import { fakeApi } from './fake-api';

// The built site against a fake API (fake-api.ts), so the layout checks
// need no coordinator.

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
    // the cards fit the scroll's height: it scrolls sideways only
    expect(await scroll.evaluate((el) => el.scrollHeight - el.clientHeight)).toBe(0);

    // the tiles and the charts below them do not touch
    const gap = await page.evaluate(() => {
      const root = document.querySelector('pool-dashboard')!.shadowRoot!;
      return root.querySelector('.charts')!.getBoundingClientRect().top - root.querySelector('pool-stats')!.getBoundingClientRect().bottom;
    });
    expect(gap).toBeGreaterThanOrEqual(8);

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
