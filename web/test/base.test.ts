import { afterEach, describe, expect, it, vi } from 'vitest';
import { PoolFeed, browserDeps } from '../src/feed';
import { FakeApi, settle } from './fake';

// The browser's fetch and EventSource, replaced by ones that record the URL
// asked for and answer from the fake API as if it were served at [base].
function served(api: FakeApi, base: string): string[] {
  const asked: string[] = [];
  const toFake = (url: string): string => {
    if (!url.startsWith(base)) return '/not-under-base' + url;
    return '/api' + url.slice(base.length);
  };
  vi.stubGlobal('fetch', async (url: string) => {
    asked.push(url);
    try {
      return new Response(JSON.stringify(await api.get(toFake(url))), { status: 200 });
    } catch {
      return new Response('{}', { status: 404 });
    }
  });
  // called with `new`, it answers the fake's source in place of itself
  vi.stubGlobal(
    'EventSource',
    vi.fn(function (url: string) {
      asked.push(url);
      return api.events();
    }),
  );
  return asked;
}

afterEach(() => vi.unstubAllGlobals());

describe('the API base', () => {
  it('A different API base: every request is under /api/testnet/, the stream included', async () => {
    const api = new FakeApi(3);
    const asked = served(api, '/api/testnet');
    const feed = new PoolFeed(browserDeps('/api/testnet'));
    await feed.start();
    api.source.open();
    await feed.loadOlder();
    await settle();
    feed.stop();

    expect(asked.length).toBeGreaterThan(2);
    expect(asked.some((u) => u.startsWith('/api/testnet/events'))).toBe(true);
    for (const u of asked) expect(u.startsWith('/api/testnet/')).toBe(true);
    expect(feed.state.pool?.tip).toBe(3);
  });

  it('the default base is /api, as the colocated proxy serves it', async () => {
    const api = new FakeApi(2);
    const asked = served(api, '/api');
    const feed = new PoolFeed(browserDeps());
    await feed.start();
    feed.stop();
    for (const u of asked) expect(u.startsWith('/api/')).toBe(true);
    expect(feed.state.pool?.tip).toBe(2);
  });

  it('a trailing slash on the base is not doubled', async () => {
    const api = new FakeApi(1);
    const asked = served(api, '/api/testnet');
    const feed = new PoolFeed(browserDeps('/api/testnet/'));
    await feed.start();
    feed.stop();
    for (const u of asked) expect(u).not.toContain('//');
  });
});
