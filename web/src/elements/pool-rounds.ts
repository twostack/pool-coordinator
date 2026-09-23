import { LitElement, css, html, nothing, type PropertyValues } from 'lit';
import { customElement, property, query } from 'lit/decorators.js';
import { repeat } from 'lit/directives/repeat.js';
import type { LiveRound, RoundRecord } from '../api';
import { FeedController } from '../controller';
import type { FeedState, PoolFeed } from '../feed';
import './pool-live-card';
import './pool-round-card';

type Item =
  | { key: string; kind: 'recorded'; record: RoundRecord }
  | { key: string; kind: 'building'; live: LiveRound }
  | { key: string; kind: 'next'; number: number };

/** How close to an end, in pixels, counts as being at it. */
const edge = 16;

/** The cards in scroll order, from the feed's state. */
export function items(s: FeedState): Item[] {
  const mined = new Set(s.rounds.filter((r) => r.minedHeight !== null).map((r) => r.number));
  // a round is live until it is mined, even when it is already recorded
  const building = (s.live?.rounds ?? []).filter((r) => !mined.has(r.number)).sort((a, b) => a.number - b.number);
  const buildingNumbers = new Set(building.map((r) => r.number));
  const out: Item[] = [];
  for (const r of s.rounds) {
    if (!buildingNumbers.has(r.number)) out.push({ key: `r${r.number}`, kind: 'recorded', record: r });
  }
  for (const r of building) out.push({ key: `r${r.number}`, kind: 'building', live: r });
  if (s.pool !== null) {
    const newest = Math.max(s.pool.tip, s.rounds.at(-1)?.number ?? 0, building.at(-1)?.number ?? 0);
    out.push({ key: 'next', kind: 'next', number: newest + 1 });
  }
  return out;
}

/**
 * The rounds as a horizontal scroll: recorded rounds oldest to newest, then
 * the round being built, then the next round. Keyed by round number, so a
 * round's live card becomes its mined card in the same place.
 *
 * It stays pinned to the newest card while the viewer is at the right end,
 * and pages older rounds in as the viewer nears the left end, keeping the
 * cards in view where they were.
 */
@customElement('pool-rounds')
export class PoolRounds extends LitElement {
  static override styles = css`
    :host {
      display: block;
      min-inline-size: 0;
    }
    .scroll {
      display: flex;
      gap: 0.75rem;
      margin: 0;
      padding: 0.25rem 0.25rem 0.75rem;
      list-style: none;
      overflow-x: auto;
      overscroll-behavior-x: contain;
      scroll-snap-type: x proximity;
    }
    .scroll:focus-visible {
      outline: 2px solid var(--pool-accent);
      outline-offset: 2px;
      border-radius: var(--pool-radius);
    }
    li {
      flex: none;
      scroll-snap-align: end;
    }
    .edge {
      display: flex;
      align-items: center;
      padding: 0 0.5rem;
      color: var(--pool-muted);
      font-size: 0.875rem;
    }
  `;

  @property({ attribute: false }) feed: PoolFeed | null = null;
  @query('.scroll') private scroller!: HTMLElement | null;

  private readonly data = new FeedController(this, () => this.feed);
  private pinned = true;
  /** The distance from the scroll's right end before older rounds were added. */
  private anchor: number | null = null;
  private oldestShown: number | null = null;

  protected override willUpdate(changed: PropertyValues<this>): void {
    if (changed.has('feed')) this.data.resubscribe();
    const el = this.scroller;
    if (el === null) return;
    this.pinned = el.scrollLeft + el.clientWidth >= el.scrollWidth - edge;
    this.anchor = el.scrollWidth - el.scrollLeft;
  }

  protected override updated(): void {
    const el = this.scroller;
    const s = this.data.state;
    if (el === null || s === null) return;
    const oldest = s.rounds[0]?.number ?? null;
    const prepended = oldest !== null && this.oldestShown !== null && oldest < this.oldestShown;
    this.oldestShown = oldest;
    if (this.pinned) {
      el.scrollLeft = el.scrollWidth;
    } else if (prepended && this.anchor !== null) {
      // the cards in view keep their place as older ones appear to their left
      el.scrollLeft = el.scrollWidth - this.anchor;
    }
    // a wide screen with few cards has nothing to scroll: page until it has
    if (el.clientWidth > 0 && el.scrollWidth <= el.clientWidth + edge) void this.feed?.loadOlder();
  }

  private onScroll(): void {
    const el = this.scroller;
    if (el === null) return;
    const card = el.querySelector('li')?.getBoundingClientRect().width ?? 0;
    if (el.scrollLeft <= Math.max(edge, card)) void this.feed?.loadOlder();
  }

  private onKey(e: KeyboardEvent): void {
    const el = this.scroller;
    if (el === null) return;
    const step = (el.querySelector('li')?.getBoundingClientRect().width ?? 240) + 12;
    const moves: Record<string, number> = {
      ArrowLeft: -step,
      ArrowRight: step,
      PageUp: -el.clientWidth,
      PageDown: el.clientWidth,
      Home: -el.scrollWidth,
      End: el.scrollWidth,
    };
    const by = moves[e.key];
    if (by === undefined) return;
    e.preventDefault();
    const still = globalThis.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? true;
    el.scrollBy({ left: by, behavior: still ? 'auto' : 'smooth' });
  }

  override render() {
    const s = this.data.state;
    if (s === null) return nothing;
    const explorer = s.pool?.explorer ?? null;
    return html`<ul
      class="scroll"
      tabindex="0"
      role="list"
      aria-label="Rounds, oldest to newest"
      @scroll=${this.onScroll}
      @keydown=${this.onKey}
    >
      ${s.reachedFirst || s.rounds.length === 0
        ? nothing
        : html`<li class="edge" aria-hidden="true">${s.loadingOlder ? 'loading older rounds…' : '…'}</li>`}
      ${repeat(
        items(s),
        (i) => i.key,
        (i) => html`<li>
          ${i.kind === 'recorded'
            ? html`<pool-round-card .record=${i.record} .explorer=${explorer}></pool-round-card>`
            : i.kind === 'building'
              ? html`<pool-live-card .number=${i.live.number} .stage=${i.live.stage}></pool-live-card>`
              : html`<pool-live-card
                  .number=${i.number}
                  .assembling=${s.live?.assembling ?? false}
                  .closesBy=${s.live?.closesBy ?? null}
                ></pool-live-card>`}
        </li>`,
      )}
    </ul>`;
  }
}

declare global {
  interface HTMLElementTagNameMap {
    'pool-rounds': PoolRounds;
  }
}
