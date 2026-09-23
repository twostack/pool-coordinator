import { LitElement, css, html, nothing } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import type { Stage } from '../api';
import { count, countdown, timeOfDay } from '../format';
import { cardStyles } from './card-styles';

/** The stages a round passes on the page, the coordinator's three between the ends. */
export const stages = ['assembling', 'proving', 'funding', 'broadcast', 'mined'] as const;

/**
 * A round that is not recorded yet: either the one being built, with its
 * stages, or the next one, which is waiting for transfers or assembling
 * until its deadline. The assembling card never shows how many transfers
 * are waiting: each arrival would be one submission's timing, which the
 * chain does not reveal.
 */
@customElement('pool-live-card')
export class PoolLiveCard extends LitElement {
  static override styles = [
    cardStyles,
    css`
      ol {
        display: flex;
        flex-direction: column;
        gap: 0.2rem;
        margin: 0.2rem 0 0;
        padding: 0;
        list-style: none;
      }
      li {
        display: flex;
        align-items: center;
        gap: 0.5rem;
        color: var(--pool-muted);
      }
      li::before {
        content: '';
        inline-size: 0.6rem;
        block-size: 0.6rem;
        border-radius: 50%;
        border: 2px solid currentColor;
      }
      li.done {
        color: var(--pool-done);
      }
      li.done::before {
        background: currentColor;
      }
      li.active {
        color: var(--pool-active);
        font-weight: 600;
      }
      .card {
        border-style: dashed;
      }
      .countdown {
        font-size: 1.5rem;
        font-variant-numeric: tabular-nums;
      }
      @media (prefers-reduced-motion: no-preference) {
        li {
          transition: color 0.4s ease;
        }
        li.active::before {
          animation: pulse 1.6s ease-in-out infinite;
        }
      }
      @keyframes pulse {
        50% {
          opacity: 0.3;
        }
      }
    `,
  ];

  @property({ type: Number }) number = 0;
  /** The round's stage when it is being built; unset for the next round. */
  @property() stage: Stage | null = null;
  @property({ type: Boolean }) assembling = false;
  /** The assembling round's deadline, in epoch seconds. */
  @property({ attribute: false }) closesBy: number | null = null;

  @state() private now = Date.now();
  private ticker: ReturnType<typeof setInterval> | null = null;

  override connectedCallback(): void {
    super.connectedCallback();
    this.ticker = setInterval(() => {
      if (this.assembling && this.closesBy !== null) this.now = Date.now();
    }, 1_000);
  }

  override disconnectedCallback(): void {
    super.disconnectedCallback();
    if (this.ticker !== null) clearInterval(this.ticker);
  }

  override render() {
    return this.stage === null ? this.next() : this.building(this.stage);
  }

  private building(stage: Stage) {
    const at = stages.indexOf(stage);
    return html`<article class="card" aria-label=${`Round ${this.number}, ${stage}`}>
      <h3>Round ${count(this.number)}</h3>
      <div class="sub">being built</div>
      <ol aria-label="Stages">
        ${stages.map((s, i) => {
          const cls = i < at ? 'done' : i === at ? 'active' : '';
          return html`<li class=${cls} aria-current=${i === at ? 'step' : 'false'}>${s}</li>`;
        })}
      </ol>
    </article>`;
  }

  private next() {
    const closesBy = this.closesBy;
    return html`<article class="card" aria-label=${`Round ${this.number}, next`}>
      <h3>Round ${count(this.number)}</h3>
      ${this.assembling
        ? html`<div class="sub">assembling</div>
            ${closesBy === null
              ? nothing
              : html`<div class="countdown" role="timer">${countdown(closesBy, this.now)}</div>
                  <div class="sub">closes by ${timeOfDay(closesBy * 1_000)}</div>`}`
        : html`<div class="sub">waiting for transfers</div>`}
    </article>`;
  }
}

declare global {
  interface HTMLElementTagNameMap {
    'pool-live-card': PoolLiveCard;
  }
}
