import type { LiveState, PoolStats, PoolSummary, RoundRecord } from '../src/api';
import type { EventSourceLike, FeedDeps } from '../src/feed';

export const txid = (n: number, kind: number): string => (n * 16 + kind).toString(16).padStart(64, '0');

export function round(n: number, over: Partial<RoundRecord> = {}): RoundRecord {
  return {
    number: n,
    y: txid(n, 1),
    round: txid(n, 2),
    witness: txid(n, 3),
    transfers: n % 4 === 0 ? 4 : n % 4,
    capacity: 4,
    balance: 100_000 + n,
    cost: 4_400,
    buildMs: 9_000,
    provingMs: 254_000,
    publishedAt: 1_790_000_000 + n * 600,
    minedHeight: 900_000 + n,
    minedAt: 1_790_000_030 + n * 600,
    ...over,
  };
}

/** A stream the test drives by hand, with the browser's ready states. */
export class FakeSource implements EventSourceLike {
  readyState = 0;
  closedByPage = false;
  private readonly handlers = new Map<string, ((e: MessageEvent<string>) => void)[]>();

  addEventListener(type: string, listener: (e: MessageEvent<string>) => void): void {
    this.handlers.set(type, [...(this.handlers.get(type) ?? []), listener]);
  }

  close(): void {
    this.readyState = 2;
    this.closedByPage = true;
  }

  open(): void {
    this.readyState = 1;
    this.fire('open', '');
  }

  send(type: 'live' | 'round', data: object): void {
    this.fire(type, JSON.stringify({ v: 1, ...data }));
  }

  /** The connection is lost; `retrying` says whether the browser reconnects by itself. */
  drop(retrying: boolean): void {
    this.readyState = retrying ? 0 : 2;
    this.fire('error', '');
  }

  private fire(type: string, data: string): void {
    for (const h of this.handlers.get(type) ?? []) h(new MessageEvent(type, { data }));
  }
}

/**
 * The coordinator's API over an in-memory history, answering the same
 * shapes and paging as lib/src/api/pool_api.dart.
 */
export class FakeApi implements FeedDeps {
  rounds: RoundRecord[] = [];
  live: LiveState = { at: 1_790_000_000, assembling: false, closesBy: null, rounds: [] };
  network = 'test';
  explorer: 'main' | 'test' | null = 'test';
  interval = 30;
  statsOver: Partial<PoolStats> = {};
  /** When false every request fails, as if the coordinator stopped answering. */
  answering = true;
  requests: string[] = [];
  sources: FakeSource[] = [];

  constructor(count = 0) {
    for (let n = 1; n <= count; n++) this.rounds.push(round(n));
  }

  get source(): FakeSource {
    const s = this.sources.at(-1);
    if (s === undefined) throw new Error('no stream opened');
    return s;
  }

  events(): EventSourceLike {
    const s = new FakeSource();
    this.sources.push(s);
    return s;
  }

  async get(path: string): Promise<unknown> {
    this.requests.push(path);
    if (!this.answering) throw new Error('unreachable');
    const url = new URL(path, 'http://pool.test');
    const tip = this.rounds.at(-1);
    switch (url.pathname) {
      case '/api/pool':
        return {
          v: 1,
          network: this.network,
          explorer: this.explorer,
          plan: 'test',
          capacity: 4,
          genesis: { issuance: txid(0, 1), witness0: txid(0, 2), slot0: txid(0, 3) },
          tip: tip?.number ?? 0,
          balance: tip?.balance ?? null,
          roundDeadlineSeconds: 600,
          publishIntervalSeconds: this.interval,
          live: this.live,
        } satisfies PoolSummary & { v: 1 };
      case '/api/rounds': {
        const before = Number(url.searchParams.get('before') ?? Infinity);
        const limit = Number(url.searchParams.get('limit') ?? 20);
        const rows = this.rounds.filter((r) => r.number < before).reverse().slice(0, limit);
        const last = rows.at(-1);
        return { v: 1, rounds: rows, next: last !== undefined && last.number > 1 ? last.number : null };
      }
      case '/api/stats':
        return {
          v: 1,
          roundsMined: this.rounds.filter((r) => r.minedHeight !== null).length,
          transfers: this.rounds.reduce((a, r) => a + r.transfers, 0),
          tip: tip?.number ?? 0,
          medianIntervalSeconds: 600,
          medianProvingSeconds: 254,
          meanCost: 4_400,
          firstPublishedAt: this.rounds[0]?.publishedAt ?? null,
          ...this.statsOver,
        } satisfies PoolStats & { v: 1 };
      case '/api/series':
        return { v: 1, metric: url.searchParams.get('metric'), bucket: url.searchParams.get('bucket'), points: [] };
      default:
        throw new Error(`${path} answered 404`);
    }
  }
}

/** Lets pending promise callbacks run under fake timers. */
export async function settle(): Promise<void> {
  for (let i = 0; i < 20; i++) await Promise.resolve();
}
