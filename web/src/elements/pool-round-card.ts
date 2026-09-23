import { LitElement, html, nothing } from 'lit';
import { customElement, property } from 'lit/decorators.js';
import type { Explorer, RoundRecord } from '../api';
import { count, dash, duration, sats, when } from '../format';
import { txLink } from '../links';
import { cardStyles } from './card-styles';

/**
 * One recorded round: its number, where it was mined, its three
 * transactions linked to the chain so a reader can check it, and how full
 * it was. Rounds rebuilt from the store have no times or cost, which show
 * as dashes.
 */
@customElement('pool-round-card')
export class PoolRoundCard extends LitElement {
  static override styles = cardStyles;

  @property({ attribute: false }) record: RoundRecord | null = null;
  @property({ attribute: false }) explorer: Explorer | null = null;

  override render() {
    const r = this.record;
    if (r === null) return nothing;
    const mined = r.minedHeight !== null;
    return html`<article class="card" aria-label=${`Round ${r.number}`}>
      <h3>Round ${count(r.number)}</h3>
      <div class="sub">${mined ? html`mined in block ${count(r.minedHeight)}` : 'awaiting block'}</div>
      <dl>
        <dt>Published</dt>
        <dd>${when(r.publishedAt)}</dd>
        <dt>Transfers</dt>
        <dd class="transfers">${count(r.transfers)} of ${count(r.capacity)}</dd>
        <dt>Proving</dt>
        <dd>${r.provingMs === null ? dash : duration(r.provingMs / 1_000)}</dd>
        <dt>Cost</dt>
        <dd>${sats(r.cost)}</dd>
        <dt>Y</dt>
        <dd>${txLink(this.explorer, r.y)}</dd>
        <dt>Round</dt>
        <dd>${txLink(this.explorer, r.round)}</dd>
        <dt>Witness</dt>
        <dd>${txLink(this.explorer, r.witness)}</dd>
      </dl>
    </article>`;
  }
}

declare global {
  interface HTMLElementTagNameMap {
    'pool-round-card': PoolRoundCard;
  }
}
