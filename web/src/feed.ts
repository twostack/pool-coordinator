import {
  roundsPath,
  seriesPath,
  versioned,
  type LiveState,
  type PoolStats,
  type PoolSummary,
  type RoundRecord,
  type RoundsPage,
  type Series,
  type SeriesBucket,
  type SeriesMetric,
} from './api';

/** The part of `EventSource` the feed uses, so tests can hand it a fake. */
export interface EventSourceLike {
  readonly readyState: number;
  addEventListener(type: string, listener: (e: MessageEvent<string>) => void): void;
  close(): void;
}

export interface FeedDeps {
  /** Fetches an API path and answers its parsed JSON body, throwing on anything but 200. */
  get(path: string): Promise<unknown>;
  /** Opens the event stream at an API path. */
  events(path: string): EventSourceLike;
}

/** Everything the widgets show, in one place so they never disagree. */
export interface FeedState {
  pool: PoolSummary | null;
  live: LiveState | null;
  stats: PoolStats | null;
  /** Recorded rounds held, oldest first, one per number. */
  rounds: RoundRecord[];
  /** Whether the oldest round held is round 1, so there is nothing left to page. */
  reachedFirst: boolean;
  loadingOlder: boolean;
  /** When the page last heard from the coordinator, in ms on the viewer's clock. */
  lastUpdate: number | null;
  /** Whether nothing has been heard for longer than {@link PoolFeed.staleAfter}. */
  stale: boolean;
}

const closed = 2;
const firstPage = 20;
const catchUpPage = 100;
/** How many pages a reconnect reads to fill a gap before it starts afresh. */
const catchUpPages = 10;
const defaultInterval = 30;

/**
 * Fetches through the browser, bounded so a hung coordinator never piles
 * requests up. The feed names its routes under `/api`; [base] is where the
 * API actually is (`/api` beside a colocated proxy, `/api/testnet` on the
 * edge site), and every request goes there instead.
 */
export function browserDeps(base = '/api'): FeedDeps {
  const at = (path: string): string => {
    if (path !== '/api' && !path.startsWith('/api/') && !path.startsWith('/api?')) throw new Error(`${path} is not an API route`);
    return base.replace(/\/+$/, '') + path.slice('/api'.length);
  };
  return {
    async get(path) {
      const r = await fetch(at(path), { signal: AbortSignal.timeout(10_000), headers: { accept: 'application/json' } });
      if (!r.ok) throw new Error(`${path} answered ${r.status}`);
      return r.json();
    },
    events: (path) => new EventSource(at(path)),
  };
}

/**
 * The page's one connection to the coordinator: the REST fetches, the one
 * event stream all widgets share, reconnection, and staleness.
 *
 * The event stream carries the live state and each round as it is mined,
 * but a browser's `EventSource` never surfaces the stream's heartbeat
 * comments, and an idle pool sends no events for hours. So the feed also
 * asks for `/api/pool` whenever it has heard nothing for a publication
 * interval; any answer or event counts as hearing from the coordinator,
 * and silence for twice the interval plus 15 s makes the data stale.
 */
export class PoolFeed {
  readonly state: FeedState = {
    pool: null,
    live: null,
    stats: null,
    rounds: [],
    reachedFirst: false,
    loadingOlder: false,
    lastUpdate: null,
    stale: false,
  };

  private readonly listeners = new Set<(s: FeedState) => void>();
  private source: EventSourceLike | null = null;
  private dropped = false;
  private backoff = 1_000;
  private reopenTimer: ReturnType<typeof setTimeout> | null = null;
  private staleTimer: ReturnType<typeof setTimeout> | null = null;
  private pollTimer: ReturnType<typeof setInterval> | null = null;
  private catchingUp: Promise<void> | null = null;
  private stopped = false;

  constructor(private readonly deps: FeedDeps) {}

  /** Seconds between the coordinator's publications of the live state. */
  get interval(): number {
    return this.state.pool?.publishIntervalSeconds ?? defaultInterval;
  }

  /** How long silence lasts before the data is stale, in ms. */
  get staleAfter(): number {
    return (2 * this.interval + 15) * 1_000;
  }

  subscribe(listener: (s: FeedState) => void): () => void {
    this.listeners.add(listener);
    listener(this.state);
    return () => this.listeners.delete(listener);
  }

  /** Loads the summary, the statistics and the newest rounds, then listens. */
  async start(): Promise<void> {
    await Promise.all([this.loadPool(), this.loadStats(), this.catchUp()]);
    if (this.stopped) return;
    this.open();
    this.pollTimer = setInterval(() => void this.poll(), 5_000);
    this.armStale();
  }

  stop(): void {
    this.stopped = true;
    this.source?.close();
    this.source = null;
    for (const t of [this.reopenTimer, this.staleTimer]) if (t !== null) clearTimeout(t);
    if (this.pollTimer !== null) clearInterval(this.pollTimer);
  }

  /** Loads the page of rounds before the oldest held, until round 1. */
  async loadOlder(): Promise<void> {
    const s = this.state;
    const oldest = s.rounds[0];
    if (s.reachedFirst || s.loadingOlder || oldest === undefined) return;
    s.loadingOlder = true;
    this.emit();
    try {
      const page = versioned<RoundsPage>(await this.deps.get(roundsPath({ before: oldest.number, limit: firstPage })));
      this.merge(page.rounds);
      s.reachedFirst = page.next === null;
      this.touch();
    } catch {
      // the next scroll to the left asks again
    } finally {
      s.loadingOlder = false;
      this.emit();
    }
  }

  /** One time series, for a chart; it is not held, since only its chart shows it. */
  async series(metric: SeriesMetric, bucket: SeriesBucket): Promise<Series> {
    const s = versioned<Series>(await this.deps.get(seriesPath(metric, bucket)));
    this.touch();
    return s;
  }

  // ---------------------------------------------------------------- stream

  private open(): void {
    if (this.stopped) return;
    const es = this.deps.events('/api/events');
    this.source = es;
    es.addEventListener('open', () => {
      this.backoff = 1_000;
      this.touch();
      if (this.dropped) {
        this.dropped = false;
        // what was mined while the stream was down is only in the history
        void Promise.all([this.loadPool(), this.loadStats(), this.catchUp()]);
      }
    });
    es.addEventListener('live', (e) => {
      const body = parse<LiveState>(e.data);
      if (body === null) return;
      this.state.live = body;
      this.touch();
    });
    es.addEventListener('round', (e) => {
      const body = parse<{ round: RoundRecord }>(e.data);
      if (body === null) return;
      const newest = this.state.rounds.at(-1);
      this.merge([body.round]);
      this.touch();
      // a round past a gap means some were missed: fill it from the history
      if (newest !== undefined && body.round.number > newest.number + 1) void this.catchUp();
      void this.loadStats();
      void this.loadPool();
    });
    es.addEventListener('error', () => {
      this.dropped = true;
      // A dropped connection the browser retries by itself; one it gave up
      // on (a refusal such as the subscriber cap) is reopened here.
      if (es.readyState === closed && this.source === es) {
        es.close();
        this.source = null;
        this.reopenTimer = setTimeout(() => this.open(), this.backoff);
        this.backoff = Math.min(this.backoff * 2, 30_000);
      }
    });
  }

  // ---------------------------------------------------------------- fetches

  private async loadPool(): Promise<void> {
    try {
      const pool = versioned<PoolSummary>(await this.deps.get('/api/pool'));
      const intervalChanged = pool.publishIntervalSeconds !== this.state.pool?.publishIntervalSeconds;
      this.state.pool = pool;
      // the stream's live state is at least as new as the summary's
      if (this.state.live === null || pool.live.at >= this.state.live.at) this.state.live = pool.live;
      this.touch();
      if (intervalChanged) this.armStale();
    } catch {
      // silence is what staleness measures
    }
  }

  private async loadStats(): Promise<void> {
    try {
      this.state.stats = versioned<PoolStats>(await this.deps.get('/api/stats'));
      this.touch();
    } catch {
      // as above
    }
  }

  /**
   * Reads the history from its newest round down to the newest held, so a
   * reconnect shows every round mined meanwhile. Concurrent calls share one
   * read.
   */
  private catchUp(): Promise<void> {
    this.catchingUp ??= this.readNewer().finally(() => (this.catchingUp = null));
    return this.catchingUp;
  }

  private async readNewer(): Promise<void> {
    const s = this.state;
    const newest = s.rounds.at(-1)?.number;
    try {
      if (newest === undefined) {
        const page = versioned<RoundsPage>(await this.deps.get(roundsPath({ limit: firstPage })));
        this.merge(page.rounds);
        s.reachedFirst = page.next === null;
        this.touch();
        return;
      }
      const found: RoundRecord[] = [];
      let before: number | undefined;
      for (let i = 0; i < catchUpPages; i++) {
        const page = versioned<RoundsPage>(await this.deps.get(roundsPath({ before, limit: catchUpPage })));
        found.push(...page.rounds);
        const lowest = page.rounds.at(-1)?.number;
        if (page.next === null || lowest === undefined || lowest <= newest + 1) {
          this.merge(found);
          this.touch();
          return;
        }
        before = page.next;
      }
      // Too far behind to fill the gap: start again from the newest rounds,
      // so the scroll never shows a hole.
      s.rounds = [];
      s.reachedFirst = false;
      this.merge(found);
      this.touch();
    } catch {
      // the next reconnect or round event tries again
    }
  }

  private async poll(): Promise<void> {
    const last = this.state.lastUpdate;
    if (last === null || Date.now() - last >= this.interval * 1_000) await this.loadPool();
  }

  // ---------------------------------------------------------------- state

  /** Adds or replaces rounds by number, keeping one per number, oldest first. */
  private merge(rounds: RoundRecord[]): void {
    if (rounds.length === 0) return;
    const byNumber = new Map(this.state.rounds.map((r) => [r.number, r]));
    for (const r of rounds) byNumber.set(r.number, r);
    this.state.rounds = [...byNumber.values()].sort((a, b) => a.number - b.number);
  }

  private touch(): void {
    this.state.lastUpdate = Date.now();
    this.state.stale = false;
    this.armStale();
    this.emit();
  }

  private armStale(): void {
    if (this.staleTimer !== null) clearTimeout(this.staleTimer);
    if (this.stopped) return;
    const last = this.state.lastUpdate ?? Date.now();
    this.staleTimer = setTimeout(() => {
      this.state.stale = true;
      this.emit();
    }, Math.max(0, last + this.staleAfter - Date.now()));
  }

  private emit(): void {
    for (const l of this.listeners) l(this.state);
  }
}

function parse<T>(data: string): T | null {
  try {
    return versioned<T>(JSON.parse(data));
  } catch {
    return null;
  }
}
