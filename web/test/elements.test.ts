import { afterEach, describe, expect, it } from 'vitest';
import type { LiveState } from '../src/api';
import '../src/elements/pool-dashboard';
import '../src/elements/pool-rounds';
import '../src/elements/pool-stats';
import { PoolFeed } from '../src/feed';
import { FakeApi, round, settle, txid } from './fake';

const feeds: PoolFeed[] = [];

afterEach(() => {
  for (const f of feeds.splice(0)) f.stop();
  document.body.replaceChildren();
});

async function started(api: FakeApi): Promise<PoolFeed> {
  const feed = new PoolFeed(api);
  feeds.push(feed);
  await feed.start();
  api.source.open();
  return feed;
}

async function mount<K extends 'pool-rounds' | 'pool-stats' | 'pool-dashboard'>(tag: K, feed: PoolFeed): Promise<HTMLElementTagNameMap[K]> {
  const el = document.createElement(tag);
  el.feed = feed;
  document.body.append(el);
  await rendered();
  return el;
}

/** Waits for every element in the page, through shadow roots, to finish rendering. */
async function rendered(): Promise<void> {
  for (let i = 0; i < 5; i++) {
    await settle();
    await Promise.all(all(document.body, '*').map((e) => (e as Partial<{ updateComplete: Promise<unknown> }>).updateComplete));
  }
}

/** Every element matching a selector, looking into shadow roots. */
function all(root: ParentNode, selector: string): Element[] {
  const out: Element[] = [];
  const walk = (node: ParentNode) => {
    for (const el of node.querySelectorAll('*')) {
      if (el.matches(selector)) out.push(el);
      if (el.shadowRoot) walk(el.shadowRoot);
    }
  };
  walk(root);
  if (root instanceof Element && root.shadowRoot) walk(root.shadowRoot);
  return out;
}

/** An element's visible text, including what its shadow root renders. */
function text(el: Element): string {
  const parts: string[] = [];
  const walk = (node: Node) => {
    if (node.nodeType === Node.TEXT_NODE) parts.push(node.textContent ?? '');
    const kids = node instanceof Element && node.shadowRoot ? node.shadowRoot.childNodes : node.childNodes;
    for (const k of kids) walk(k);
  };
  walk(el);
  return parts.join(' ').replace(/\s+/g, ' ').trim();
}

function cardNumbers(root: Element): number[] {
  return all(root, 'pool-round-card').map((c) => (c as HTMLElementTagNameMap['pool-round-card']).record?.number ?? -1);
}

function send(api: FakeApi, live: Partial<LiveState>): void {
  api.live = { at: api.live.at + 30, assembling: false, closesBy: null, rounds: [], ...live };
  api.source.send('live', api.live);
}

describe('the round scroll', () => {
  it('Two rounds render', async () => {
    const api = new FakeApi(2);
    const el = await mount('pool-rounds', await started(api));
    expect(cardNumbers(el)).toEqual([1, 2]);
    for (const [i, card] of all(el, 'pool-round-card').entries()) {
      const n = i + 1;
      const hrefs = all(card, 'a').map((a) => a.getAttribute('href'));
      expect(hrefs).toEqual([1, 2, 3].map((k) => `https://test.whatsonchain.com/tx/${txid(n, k)}`));
      expect(text(all(card, '.transfers')[0]!)).toBe(`${n} of 4`);
    }
  });

  it('Paging left: older rounds are prepended without moving the cards in view', async () => {
    const api = new FakeApi(60);
    const el = await mount('pool-rounds', await started(api));
    expect(cardNumbers(el)).toEqual(range(41, 60));

    // happy-dom has no layout, so the scroll's geometry is given: 200 px a card
    const scroller = el.shadowRoot!.querySelector<HTMLElement>('.scroll')!;
    let left = 0;
    Object.defineProperties(scroller, {
      scrollWidth: { get: () => scroller.querySelectorAll('li').length * 200 },
      clientWidth: { get: () => 600 },
      scrollLeft: { get: () => left, set: (v: number) => (left = v) },
    });
    left = 0;
    // the edge marker stays leftmost, so compare the cards right of it
    const inView = [...scroller.querySelectorAll('li')].slice(1, 4).map(liNumber);
    scroller.dispatchEvent(new Event('scroll'));
    await rendered();

    expect(api.requests).toContain('/api/rounds?before=41&limit=20');
    expect(cardNumbers(el)).toEqual(range(21, 60));
    // the cards that were at the left edge are still at the scroll position
    const lis = [...scroller.querySelectorAll('li')];
    const first = Math.round(left / 200);
    expect(lis.slice(first + 1, first + 4).map(liNumber)).toEqual(inView);
    expect(inView).toEqual([41, 42, 43]);
  });

  it('A round moves through its stages and ends as a mined card in place', async () => {
    const api = new FakeApi(2);
    const el = await mount('pool-rounds', await started(api));
    const liOf = (n: number) => [...el.shadowRoot!.querySelectorAll('li')].findIndex((li) => liNumber(li) === n);

    for (const [i, stage] of (['proving', 'funding', 'broadcast'] as const).entries()) {
      send(api, { rounds: [{ number: 3, stage }] });
      await rendered();
      const card = all(el, 'pool-live-card').find((c) => (c as HTMLElementTagNameMap['pool-live-card']).number === 3)!;
      expect(text(all(card, '[aria-current=step]')[0]!)).toBe(stage);
      expect(all(card, 'li.done').map((d) => text(d))).toEqual(['assembling', 'proving', 'funding', 'broadcast'].slice(0, i + 1));
    }
    const liveAt = liOf(3);

    api.rounds.push(round(3));
    api.source.send('round', { round: round(3) });
    await rendered();
    expect(cardNumbers(el)).toEqual([1, 2, 3]);
    expect(all(el, 'pool-live-card').map((c) => (c as HTMLElementTagNameMap['pool-live-card']).stage)).toEqual([null]);
    expect(liOf(3)).toBe(liveAt);

    // the stale live state that still names round 3 does not bring its live card back
    send(api, { rounds: [{ number: 3, stage: 'broadcast' }] });
    await rendered();
    expect(cardNumbers(el)).toEqual([1, 2, 3]);
  });

  it('No transfer counts while assembling', async () => {
    const api = new FakeApi(2);
    const el = await mount('pool-rounds', await started(api));
    const next = () => all(el, 'pool-live-card').at(-1)!;
    expect(text(next())).toContain('waiting for transfers');

    send(api, { assembling: true, closesBy: Math.ceil(Date.now() / 1_000) + 300 });
    await rendered();
    const shown = text(next());
    expect(shown).toMatch(/^Round 3 assembling \d:\d\d closes by /);
    expect(shown).not.toMatch(/transfer|pending|of \d/i);
  });
});

describe('the statistics', () => {
  it('Tiles from the stats route', async () => {
    const api = new FakeApi(2);
    api.statsOver = { roundsMined: 2, transfers: 7, meanCost: null };
    const el = await mount('pool-stats', await started(api));
    const tile = (label: string) => {
      const dt = all(el, 'dt').find((d) => text(d) === label)!;
      return text(dt.nextElementSibling!);
    };
    expect(tile('Rounds mined')).toBe('2');
    expect(tile('Transfers')).toBe('7');
    expect(tile('Mean round cost')).toBe('–');
    expect(tile('Capacity')).toBe('4 a round');
    expect(all(el, 'a').map((a) => a.getAttribute('href'))).toEqual([`https://test.whatsonchain.com/tx/${txid(0, 1)}`]);
  });
});

describe('links to the chain', () => {
  it('Testnet links', async () => {
    const api = new FakeApi(3);
    const el = await mount('pool-dashboard', await started(api));
    const links = all(el, 'a.txid');
    expect(links).toHaveLength(3 * 3 + 1);
    for (const a of links) {
      expect(a.getAttribute('href')).toMatch(/^https:\/\/test\.whatsonchain\.com\/tx\/[0-9a-f]{64}$/);
      expect(a.getAttribute('href')).toBe(`https://test.whatsonchain.com/tx/${a.getAttribute('title')}`);
    }
  });

  it('mainnet links to the main explorer, regtest links nowhere', async () => {
    const main = new FakeApi(1);
    main.network = 'main';
    main.explorer = 'main';
    const el = await mount('pool-dashboard', await started(main));
    expect(all(el, 'a.txid').every((a) => a.getAttribute('href')!.startsWith('https://whatsonchain.com/tx/'))).toBe(true);
    el.remove();

    const regtest = new FakeApi(1);
    regtest.explorer = null;
    const r = await mount('pool-dashboard', await started(regtest));
    expect(all(r, 'a')).toHaveLength(0);
    expect(all(r, 'span.txid')).toHaveLength(3 + 1);
    expect(text(r)).toContain('regtest');
  });

  it('Malformed txid', async () => {
    const api = new FakeApi(0);
    api.rounds.push(round(1, { witness: 'abc123', round: txid(1, 2).toUpperCase() + '0' }));
    const el = await mount('pool-rounds', await started(api));
    const card = all(el, 'pool-round-card')[0]!;
    expect(all(card, 'a').map((a) => a.getAttribute('title'))).toEqual([txid(1, 1)]);
    expect(all(card, 'span.txid').map((s) => text(s))).toEqual([txid(1, 2).toUpperCase() + '0', 'abc123']);
  });
});

describe('API data is text', () => {
  it('Markup in a field', async () => {
    const markup = '<img src=x onerror=alert(1)>';
    const api = new FakeApi(0);
    api.network = markup;
    api.rounds.push(round(1, { witness: markup }));
    const el = await mount('pool-dashboard', await started(api));
    expect(all(document.body, 'img')).toHaveLength(0);
    expect(all(document.body, '[onerror]')).toHaveLength(0);
    expect(text(all(el, 'header')[0]!)).toContain(markup);
    expect(all(el, 'span.txid').map((s) => text(s))).toContain(markup);
    expect(all(el, 'span.txid').map((s) => s.getAttribute('title'))).toContain(markup);
  });
});

/** The round a scroll item shows, whether its card is live or recorded. */
function liNumber(li: Element): number | null {
  const card = li.querySelector('pool-round-card, pool-live-card') as
    | (Element & { record?: { number: number } | null; number?: number })
    | null;
  return card?.record?.number ?? card?.number ?? null;
}

function range(from: number, to: number): number[] {
  return Array.from({ length: to - from + 1 }, (_, i) => from + i);
}
