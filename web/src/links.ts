import { html, type TemplateResult } from 'lit';
import type { Explorer } from './api';

// The only places a link can point. The coordinator names an explorer and
// the page picks its origin from this table, so a served string never
// becomes a URL by itself.
const explorers: Record<Explorer, string> = {
  main: 'https://whatsonchain.com',
  test: 'https://test.whatsonchain.com',
};

/** Whether a served value is a txid: exactly 64 hex characters. */
export function isTxid(s: unknown): s is string {
  return typeof s === 'string' && /^[0-9a-f]{64}$/i.test(s);
}

/** The explorer's page for a txid, or null when the chain has no explorer or the txid is malformed. */
export function txUrl(explorer: Explorer | null | undefined, txid: unknown): string | null {
  if (explorer !== 'main' && explorer !== 'test') return null;
  if (!isTxid(txid)) return null;
  return `${explorers[explorer]}/tx/${txid.toLowerCase()}`;
}

/** A txid shortened for a card, whole in the title. */
export function shortTxid(txid: string): string {
  return isTxid(txid) ? `${txid.slice(0, 8)}…${txid.slice(-8)}` : txid;
}

/**
 * A txid as a link to the chain when it is checkable there, as text
 * otherwise. Lit writes both the text and the attributes as text, so a
 * malformed value is shown literally.
 */
export function txLink(explorer: Explorer | null | undefined, txid: string, label?: string): TemplateResult {
  const url = txUrl(explorer, txid);
  const text = label ?? shortTxid(txid);
  return url === null
    ? html`<span class="txid" title=${txid}>${text}</span>`
    : html`<a class="txid" href=${url} title=${txid} rel="noopener noreferrer" target="_blank">${text}</a>`;
}
