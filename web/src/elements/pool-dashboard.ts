import { LitElement, css, html, nothing, type PropertyValues } from 'lit';
import { customElement, property } from 'lit/decorators.js';
import { FeedController } from '../controller';
import type { PoolFeed } from '../feed';
import { timeOfDay } from '../format';
import './pool-chart';
import './pool-rounds';
import './pool-stats';

/** The chain the pool runs on, in words; a name the page does not know is shown as served. */
export function networkName(network: string, explorer: string | null | undefined): string {
  if (network === 'main') return 'mainnet';
  if (network === 'test') return explorer === 'test' ? 'testnet' : 'regtest';
  return network;
}

/**
 * The page: its heading, the stale notice, the round scroll, the tiles and
 * the charts, all fed by the one feed it is given.
 */
@customElement('pool-dashboard')
export class PoolDashboard extends LitElement {
  static override styles = css`
    :host {
      display: block;
      font-family: var(--pool-font);
      color: var(--pool-text);
      max-inline-size: 72rem;
      margin: 0 auto;
      padding: 1rem;
    }
    header {
      display: flex;
      flex-wrap: wrap;
      align-items: baseline;
      gap: 0.25rem 0.75rem;
    }
    h1 {
      margin: 0;
      font-size: 1.5rem;
    }
    h2 {
      margin: 1.5rem 0 0.6rem;
      font-size: 1.05rem;
    }
    .network {
      color: var(--pool-muted);
    }
    .stale {
      margin: 0.75rem 0 0;
      padding: 0.5rem 0.75rem;
      border-radius: var(--pool-radius);
      background: var(--pool-warn-bg);
      color: var(--pool-warn-text);
    }
    .charts {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(16rem, 1fr));
      gap: 0.75rem;
      margin-top: 0.75rem;
    }
    pool-chart {
      display: block;
      min-inline-size: 0;
      padding: 0.75rem;
      border: 1px solid var(--pool-border);
      border-radius: var(--pool-radius);
      background: var(--pool-surface);
    }
    footer {
      margin-top: 2rem;
      color: var(--pool-muted);
      font-size: 0.8rem;
    }
  `;

  @property({ attribute: false }) feed: PoolFeed | null = null;
  private readonly data = new FeedController(this, () => this.feed);

  protected override willUpdate(changed: PropertyValues<this>): void {
    if (changed.has('feed')) this.data.resubscribe();
  }

  override render() {
    const s = this.data.state;
    const pool = s?.pool ?? null;
    return html`<header>
        <h1>BSV Shielded Pool</h1>
        ${pool === null ? nothing : html`<span class="network">${networkName(pool.network, pool.explorer)}</span>`}
      </header>
      ${s?.stale
        ? html`<p class="stale" role="status">
            The coordinator has not answered for a while; this data is stale.
            ${s.lastUpdate === null ? nothing : html`Last updated ${timeOfDay(s.lastUpdate)}.`}
          </p>`
        : nothing}
      <h2>Rounds</h2>
      <pool-rounds .feed=${this.feed}></pool-rounds>
      <h2>The pool</h2>
      <pool-stats .feed=${this.feed}></pool-stats>
      <div class="charts">
        <pool-chart .feed=${this.feed} metric="rounds" label="Rounds mined" bars></pool-chart>
        <pool-chart .feed=${this.feed} metric="transfers" label="Transfers" bars></pool-chart>
        <pool-chart .feed=${this.feed} metric="balance" label="Pool balance (BSV)" scale="100000000"></pool-chart>
      </div>
      ${pool?.explorer
        ? html`<footer>Every round links to its transactions on the chain, where it can be checked.</footer>`
        : nothing}`;
  }
}

declare global {
  interface HTMLElementTagNameMap {
    'pool-dashboard': PoolDashboard;
  }
}
