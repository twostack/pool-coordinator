import { LitElement, css, html, nothing, type PropertyValues } from 'lit';
import { customElement, property, state } from 'lit/decorators.js';
import { FeedController } from '../controller';
import type { PoolFeed } from '../feed';

/** The networks cloak takes, by cloak's names. */
export type CloakNetwork = 'testnet' | 'mainnet' | 'regtest';

/** What `/api/pool`'s `wallet` holds once it has passed [connectBlocks]. */
export interface WalletConnect {
  network: CloakNetwork;
  server: string;
  coordinator: string;
  peers: string[];
  arcUrl: string | null;
}

/** The two blocks a user copies: the init command and the whole config. */
export interface ConnectBlocks {
  command: string;
  config: string;
}

// Anchored, bounded and ASCII only. What these accept ends up in a shell
// and a YAML file, so the grammar is closed: a value that is not exactly
// one of these hides the whole section, since half a command still gets
// pasted.
const octet = '(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])';
const ip4 = new RegExp(`^${octet}(\\.${octet}){3}$`);
const ip6 = /^[0-9A-Fa-f:.]{2,45}$/;
const peerId = /^[1-9A-HJ-NP-Za-km-z]{46,60}$/;
const serverShape = /^\/(ip4|ip6)\/([^/]{1,45})\/udp\/([0-9]{1,5})\/udx\/p2p\/([^/]{1,60})$/;
const hostName = /^(?=.{1,253}$)[A-Za-z0-9-]{1,63}(\.[A-Za-z0-9-]{1,63})*$/;
const arcShape = /^https:\/\/[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?(\/[A-Za-z0-9._~/-]{0,200})?$/;
const maxPeers = 8;

function port(p: string): boolean {
  const n = Number(p);
  return /^[1-9][0-9]{0,4}$/.test(p) && n >= 1 && n <= 65535;
}

function isServer(s: unknown): s is string {
  if (typeof s !== 'string') return false;
  const m = serverShape.exec(s);
  if (m === null) return false;
  const [, kind, addr, p, id] = m as unknown as [string, string, string, string, string];
  const addrOk = kind === 'ip4' ? ip4.test(addr) : ip6.test(addr) && addr.includes(':');
  return addrOk && port(p) && peerId.test(id);
}

function isPeer(s: unknown): s is string {
  if (typeof s !== 'string' || s.length > 260) return false;
  const i = s.lastIndexOf(':');
  if (i < 1) return false;
  const host = s.slice(0, i);
  return (ip4.test(host) || hostName.test(host)) && port(s.slice(i + 1));
}

function isArc(s: unknown): s is string {
  if (typeof s !== 'string' || !arcShape.test(s)) return false;
  const m = /^https:\/\/[^/:]+:([0-9]+)/.exec(s);
  return m === null || port(m[1] as string);
}

/** [w] as a [WalletConnect] when every value passes, otherwise null. */
export function walletConnect(w: unknown): WalletConnect | null {
  if (typeof w !== 'object' || w === null) return null;
  const o = w as Record<string, unknown>;
  const network = o['network'];
  if (network !== 'testnet' && network !== 'mainnet' && network !== 'regtest') return null;
  if (!isServer(o['server'])) return null;
  if (typeof o['coordinator'] !== 'string' || !peerId.test(o['coordinator'])) return null;
  const peers = o['peers'] ?? [];
  if (!Array.isArray(peers) || peers.length > maxPeers || !peers.every(isPeer)) return null;
  const arc = o['arcUrl'] ?? null;
  if (arc !== null && !isArc(arc)) return null;
  return { network, server: o['server'], coordinator: o['coordinator'], peers: [...peers], arcUrl: arc };
}

/**
 * The command and the config file for [w], or null when anything in it
 * fails the grammar. The file is cloak's config version 1 as `cloak init`
 * writes it, with cloak's defaults, whole: the file init writes already has
 * `chain:` and `arc:`, so lines to merge would give a key twice.
 */
export function connectBlocks(w: unknown): ConnectBlocks | null {
  const c = walletConnect(w);
  if (c === null) return null;
  const command = `cloak init --network ${c.network} --server ${c.server} --pool ${c.coordinator}`;
  const peers = c.peers.length === 0 ? ['  peers: []'] : ['  peers:', ...c.peers.map((p) => `    - ${p}`)];
  const config = [
    "# A cloak wallet's settings. Nothing here is secret: the passphrase comes from a prompt",
    '# or CLOAK_PASSPHRASE, never from this file.',
    'version: 1',
    `network: ${c.network}`,
    'pool:',
    '  # the ricochet server, as a multiaddr ending in /p2p/<peer id>',
    `  server: ${c.server}`,
    "  # the coordinator's peer id; its feed is the pool's",
    `  coordinator: ${c.coordinator}`,
    '  timeout_seconds: 30',
    'chain:',
    '  # blocks deep before a payment counts, the block itself counting as one',
    `  confirmations: ${c.network === 'regtest' ? 1 : 6}`,
    ...peers,
    'deposit:',
    "  # blocks beyond the next round that a deposit's refund opens at",
    '  refund_margin: 144',
    '  # the fewest blocks past the tip a refund may open at; a coordinator skips a sooner one',
    '  refund_minimum: 100',
    'arc:',
    `  url: ${c.arcUrl ?? '~'}`,
    '',
  ].join('\n');
  return { command, config };
}

/**
 * How to join the pool with cloak: the `cloak init` command and the whole
 * `config.yaml` for a new wallet, each with a copy button, from
 * `/api/pool`'s `wallet`. The host hides itself when the pool names no
 * wallet settings or any of them fails the grammar, so a page can give it
 * an id to link to without leaving an empty target.
 */
@customElement('pool-connect')
export class PoolConnect extends LitElement {
  static override styles = css`
    :host {
      display: block;
      font-family: var(--pool-font);
      color: var(--pool-text);
    }
    :host([hidden]) {
      display: none;
    }
    h2 {
      font-size: 1.15rem;
      margin: 2rem 0 0.5rem;
    }
    p {
      margin: 0.5rem 0;
      color: var(--pool-muted);
      font-size: 0.9rem;
    }
    .block {
      position: relative;
      margin: 0.5rem 0 1rem;
      border: 1px solid var(--pool-border);
      border-radius: var(--pool-radius);
      background: var(--pool-surface);
    }
    pre {
      margin: 0;
      padding: 0.75rem 0.9rem;
      padding-inline-end: 5.5rem;
      overflow-x: auto;
      font-family: var(--pool-mono);
      font-size: 0.82rem;
      line-height: 1.45;
      white-space: pre;
    }
    button {
      position: absolute;
      inset-block-start: 0.5rem;
      inset-inline-end: 0.5rem;
      font: inherit;
      font-size: 0.8rem;
      padding: 0.25rem 0.6rem;
      border: 1px solid var(--pool-border);
      border-radius: var(--pool-radius);
      background: var(--pool-surface);
      color: var(--pool-accent);
      cursor: pointer;
    }
    code {
      font-family: var(--pool-mono);
    }
    a {
      color: var(--pool-accent);
    }
  `;

  @property({ attribute: false }) feed: PoolFeed | null = null;
  @state() private copied: 'command' | 'config' | null = null;
  @state() private selectHint: 'command' | 'config' | null = null;

  private readonly data = new FeedController(this, () => this.feed);
  private reset: ReturnType<typeof setTimeout> | null = null;

  protected override willUpdate(changed: PropertyValues<this>): void {
    if (changed.has('feed')) this.data.resubscribe();
    this.hidden = this.blocks() === null;
  }

  private shown = false;

  protected override updated(): void {
    // The page's fragment scroll happens on load, while the host is still
    // hidden for want of the pool's summary; so the first time it shows,
    // it does that scroll itself if the address points at it.
    if (this.hidden || this.shown) return;
    this.shown = true;
    if (this.id !== '' && location.hash === `#${this.id}`) this.scrollIntoView();
  }

  override disconnectedCallback(): void {
    super.disconnectedCallback();
    if (this.reset !== null) clearTimeout(this.reset);
  }

  private blocks(): ConnectBlocks | null {
    return connectBlocks(this.data.state?.pool?.wallet ?? null);
  }

  private async copy(which: 'command' | 'config', text: string): Promise<void> {
    try {
      await navigator.clipboard.writeText(text);
      this.copied = which;
      this.selectHint = null;
    } catch {
      // no clipboard (an old browser, or permission refused): select the
      // block so a keyboard copy takes exactly it
      const pre = this.renderRoot.querySelector(`pre[data-block="${which}"]`);
      const selection = getSelection();
      if (pre !== null && selection !== null) {
        const range = document.createRange();
        range.selectNodeContents(pre);
        selection.removeAllRanges();
        selection.addRange(range);
      }
      this.copied = null;
      this.selectHint = which;
    }
    if (this.reset !== null) clearTimeout(this.reset);
    this.reset = setTimeout(() => {
      this.copied = null;
      this.selectHint = null;
    }, 2_000);
  }

  private label(which: 'command' | 'config'): string {
    if (this.copied === which) return 'Copied';
    if (this.selectHint === which) return 'Selected';
    return 'Copy';
  }

  override render() {
    const b = this.blocks();
    if (b === null) return nothing;
    return html`<h2>Connect a wallet</h2>
      <p>Make a wallet for this pool with <a href="https://github.com/twostack/cloak-cli">cloak</a>:</p>
      <div class="block">
        <pre data-block="command">${b.command}</pre>
        <button type="button" aria-label=${`${this.label('command')}: the cloak init command`} @click=${() => this.copy('command', b.command)}>
          ${this.label('command')}
        </button>
      </div>
      <p>Then replace the new wallet's <code>config.yaml</code> with this, which also names chain peers and an ARC endpoint that answer without a key:</p>
      <div class="block">
        <pre data-block="config">${b.config}</pre>
        <button type="button" aria-label=${`${this.label('config')}: the config file`} @click=${() => this.copy('config', b.config)}>
          ${this.label('config')}
        </button>
      </div>`;
  }
}

declare global {
  interface HTMLElementTagNameMap {
    'pool-connect': PoolConnect;
  }
}
