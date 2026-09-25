import { css } from 'lit';

/** What the round cards share, so a live card and a mined one line up. */
export const cardStyles = css`
  :host {
    display: block;
    font-family: var(--pool-font);
    inline-size: var(--pool-card-width);
    block-size: 100%;
  }
  .card {
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
    box-sizing: border-box;
    block-size: 100%;
    padding: 0.85rem 1rem;
    border: 1px solid var(--pool-border);
    border-radius: var(--pool-radius);
    background: var(--pool-surface);
    color: var(--pool-text);
    font-size: 0.875rem;
  }
  h3 {
    margin: 0;
    font-size: 1rem;
  }
  .sub {
    color: var(--pool-muted);
  }
  dl {
    display: grid;
    grid-template-columns: auto minmax(0, 1fr);
    gap: 0.15rem 0.6rem;
    margin: 0;
  }
  dt {
    color: var(--pool-muted);
  }
  dd {
    margin: 0;
    min-inline-size: 0;
  }
  .txid {
    display: block;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
    font-family: var(--pool-mono);
    font-size: 0.8rem;
  }
  a {
    color: var(--pool-accent);
  }
  a:focus-visible {
    outline: 2px solid var(--pool-accent);
    outline-offset: 2px;
  }
`;
