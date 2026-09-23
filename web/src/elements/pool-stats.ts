import { LitElement, css, html, nothing, type PropertyValues } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { FeedController } from '../controller';
import type { PoolFeed } from '../feed';
import { bsv, count, dash, duration, sats } from '../format';
import { txLink } from '../links';

/**
 * The pool's overall numbers as tiles, from `/api/stats` and `/api/pool`.
 * A figure the coordinator has not recorded yet is a dash, never a zero.
 */
@customElement('pool-stats')
export class PoolStats extends LitElement {
  static override styles = css`
    :host {
      display: block;
    }
    dl {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(9.5rem, 1fr));
      gap: 0.75rem;
      margin: 0;
    }
    div {
      padding: 0.75rem 0.9rem;
      border: 1px solid var(--pool-border);
      border-radius: var(--pool-radius);
      background: var(--pool-surface);
      min-inline-size: 0;
    }
    dt {
      color: var(--pool-muted);
      font-size: 0.8rem;
    }
    dd {
      margin: 0.15rem 0 0;
      font-size: 1.25rem;
      font-weight: 600;
      font-variant-numeric: tabular-nums;
      overflow-wrap: anywhere;
    }
    .txid {
      display: block;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      font-family: var(--pool-mono);
      font-size: 0.9rem;
      font-weight: 400;
    }
    a {
      color: var(--pool-accent);
    }
  `;

  @property({ attribute: false }) feed: PoolFeed | null = null;
  @state() private now = Date.now();

  private readonly data = new FeedController(this, () => this.feed);
  private ticker: ReturnType<typeof setInterval> | null = null;

  override connectedCallback(): void {
    super.connectedCallback();
    // the pool's age moves on by itself
    this.ticker = setInterval(() => (this.now = Date.now()), 60_000);
  }

  override disconnectedCallback(): void {
    super.disconnectedCallback();
    if (this.ticker !== null) clearInterval(this.ticker);
  }

  protected override willUpdate(changed: PropertyValues<this>): void {
    if (changed.has('feed')) this.data.resubscribe();
  }

  override render() {
    const s = this.data.state;
    if (s === null) return nothing;
    const st = s.stats;
    const pool = s.pool;
    const first = st?.firstPublishedAt ?? null;
    const tiles: [string, unknown][] = [
      ['Rounds mined', count(st?.roundsMined)],
      ['Transfers', count(st?.transfers)],
      ['Median round interval', duration(st?.medianIntervalSeconds)],
      ['Capacity', pool === null ? dash : `${count(pool.capacity)} a round`],
      ['Mean round cost', sats(st?.meanCost)],
      ['Median proving time', duration(st?.medianProvingSeconds)],
      ['Pool balance', bsv(pool?.balance)],
      ['Pool age', first === null ? dash : duration(this.now / 1_000 - first)],
      ['Genesis', pool === null ? dash : txLink(pool.explorer, pool.genesis.issuance)],
    ];
    return html`<dl>
      ${tiles.map(([label, value]) => html`<div><dt>${label}</dt><dd>${value}</dd></div>`)}
    </dl>`;
  }
}

declare global {
  interface HTMLElementTagNameMap {
    'pool-stats': PoolStats;
  }
}
