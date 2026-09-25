// A fake coordinator API for the browser checks: every request under the
// API base is answered here, so no coordinator is needed.
import type { Page } from '@playwright/test';

const txid = (n: number, kind: number) => (n * 16 + kind).toString(16).padStart(64, '0');
const live = { at: 1_790_000_000, assembling: true, closesBy: Math.ceil(Date.now() / 1_000) + 300, rounds: [{ number: 31, stage: 'proving' }] };

function round(n: number) {
  return {
    number: n, y: txid(n, 1), round: txid(n, 2), witness: txid(n, 3), transfers: 3, capacity: 4,
    balance: 100_000 + n, cost: 4_400, buildMs: 9_000, provingMs: 254_000,
    publishedAt: 1_790_000_000 + n * 600, minedHeight: 900_000 + n, minedAt: 1_790_000_030 + n * 600,
  };
}

export interface FakeOptions {
  /** Where the page asks for the API: `/api`, or `/api/testnet` on the edge site. */
  base?: string;
  /** Replaces the pool's network name and genesis issuance, for markup checks. */
  network?: string;
  issuance?: string;
  /** Every API path the page asked for, in order. */
  asked?: string[];
  /** `/api/pool`'s `wallet`; null, as for a pool that names none, by default. */
  wallet?: unknown;
}

export async function fakeApi(page: Page, opts: FakeOptions = {}): Promise<void> {
  const base = opts.base ?? '/api';
  await page.route(`**${base}/**`, async (route) => {
    const url = new URL(route.request().url());
    opts.asked?.push(url.pathname + url.search);
    const path = '/api' + url.pathname.slice(base.length);
    const json = (body: object) => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ v: 1, ...body }) });
    switch (path) {
      case '/api/pool':
        return json({
          network: opts.network ?? 'test', explorer: 'test', plan: 'test', capacity: 4,
          genesis: { issuance: opts.issuance ?? txid(0, 1), witness0: txid(0, 2), slot0: txid(0, 3) },
          tip: 30, balance: 100_030, roundDeadlineSeconds: 600, publishIntervalSeconds: 30, live,
          wallet: opts.wallet ?? null,
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

