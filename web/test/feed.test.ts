import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { PoolFeed } from '../src/feed';
import { FakeApi, round, settle } from './fake';

describe('the feed', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it('loads the newest page and the summary, then listens on one stream', async () => {
    const api = new FakeApi(3);
    const feed = new PoolFeed(api);
    await feed.start();
    expect(feed.state.rounds.map((r) => r.number)).toEqual([1, 2, 3]);
    expect(feed.state.reachedFirst).toBe(true);
    expect(feed.state.pool?.tip).toBe(3);
    expect(api.sources).toHaveLength(1);
    feed.stop();
  });

  it('Stream drops and returns: the round mined meanwhile shows, once', async () => {
    const api = new FakeApi(3);
    const feed = new PoolFeed(api);
    await feed.start();
    api.source.open();

    api.source.drop(true);
    api.rounds.push(round(4));
    // the browser reconnects the same stream and says so
    api.source.open();
    await settle();
    expect(feed.state.rounds.map((r) => r.number)).toEqual([1, 2, 3, 4]);

    // the same round arriving again as an event never makes a second card
    api.source.send('round', { round: round(4) });
    expect(feed.state.rounds.map((r) => r.number)).toEqual([1, 2, 3, 4]);
    feed.stop();
  });

  it('a stream the browser gave up on is reopened, and what it missed is read', async () => {
    const api = new FakeApi(3);
    const feed = new PoolFeed(api);
    await feed.start();
    api.source.open();

    api.source.drop(false);
    expect(api.sources).toHaveLength(1);
    api.rounds.push(round(4), round(5));
    await vi.advanceTimersByTimeAsync(1_000);
    expect(api.sources).toHaveLength(2);
    api.source.open();
    await settle();
    expect(feed.state.rounds.map((r) => r.number)).toEqual([1, 2, 3, 4, 5]);
    feed.stop();
  });

  it('a round past a gap fills the gap from the history', async () => {
    const api = new FakeApi(3);
    const feed = new PoolFeed(api);
    await feed.start();
    api.source.open();
    api.rounds.push(round(4), round(5));
    api.source.send('round', { round: round(5) });
    await settle();
    expect(feed.state.rounds.map((r) => r.number)).toEqual([1, 2, 3, 4, 5]);
    feed.stop();
  });

  it('Coordinator unreachable: stale within twice the interval plus 15 s, cards kept', async () => {
    const api = new FakeApi(2);
    const feed = new PoolFeed(api);
    await feed.start();
    api.source.open();
    const lastHeard = feed.state.lastUpdate;

    api.answering = false;
    // the stream hangs rather than closing, so only silence tells
    await vi.advanceTimersByTimeAsync((2 * 30 + 15) * 1_000 - 1);
    expect(feed.state.stale).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    expect(feed.state.stale).toBe(true);
    expect(feed.state.lastUpdate).toBe(lastHeard);
    expect(feed.state.rounds.map((r) => r.number)).toEqual([1, 2]);
    // it kept asking while silent
    expect(api.requests.filter((p) => p === '/api/pool').length).toBeGreaterThan(1);

    api.answering = true;
    await vi.advanceTimersByTimeAsync(5_000);
    expect(feed.state.stale).toBe(false);
    feed.stop();
  });

  it('an idle pool that still answers is never stale', async () => {
    const api = new FakeApi(2);
    const feed = new PoolFeed(api);
    await feed.start();
    api.source.open();
    await vi.advanceTimersByTimeAsync(60 * 60 * 1_000);
    expect(feed.state.stale).toBe(false);
    feed.stop();
  });

  it('pages left until round 1, holding one card per round', async () => {
    const api = new FakeApi(45);
    const feed = new PoolFeed(api);
    await feed.start();
    expect(feed.state.rounds.map((r) => r.number)).toEqual([...Array(20).keys()].map((i) => 26 + i));
    await feed.loadOlder();
    await feed.loadOlder();
    expect(feed.state.rounds.map((r) => r.number)).toEqual([...Array(45).keys()].map((i) => 1 + i));
    expect(feed.state.reachedFirst).toBe(true);
    const asked = api.requests.length;
    await feed.loadOlder();
    expect(api.requests.length).toBe(asked);
    feed.stop();
  });

  it('ignores an event of another version', async () => {
    const api = new FakeApi(1);
    const feed = new PoolFeed(api);
    await feed.start();
    api.source.open();
    const before = feed.state.live;
    api.source.send('live', { v: 2, at: 1, assembling: true, closesBy: null, rounds: [] });
    expect(feed.state.live).toBe(before);
    feed.stop();
  });
});
