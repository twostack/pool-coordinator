# pool-elements

The BSV Shielded Pool dashboard's elements, for a page that embeds them: the live round, the rounds as they are mined, the pool's statistics and its charts. They read the pool coordinator's read-only API and nothing else.

Each pool-coordinator release attaches this package as `pool-elements-X.Y.Z.tgz`. Install it by URL, so the lockfile pins its integrity:

```sh
npm install https://github.com/twostack/pool-coordinator/releases/download/vX.Y.Z/pool-elements-X.Y.Z.tgz
```

Lit and uPlot are bundled in. The module loads nothing from anywhere but the page's own origin, so it works under a content security policy of `'self'`.

## Use

```js
import 'pool-elements/tokens.css'; // the default theme; optional
import { PoolFeed, browserDeps } from 'pool-elements';

// where the API is: `/api` beside the colocated proxy, `/api/testnet` on shieldpool.net
const feed = new PoolFeed(browserDeps('/api/testnet'));
for (const el of document.querySelectorAll('pool-stats, pool-rounds, pool-chart, pool-dashboard')) el.feed = feed;
void feed.start();
```

One feed drives any number of elements, over one event stream.

| Element | Fed by | Shows |
|---|---|---|
| `<pool-dashboard>` | `.feed` | everything below, as one page |
| `<pool-rounds>` | `.feed` | the rounds as a horizontal scroll, with the live cards at its end |
| `<pool-stats>` | `.feed` | the pool's figures as tiles |
| `<pool-chart metric="rounds\|transfers\|balance" label="…" [bars] [scale="…"]>` | `.feed` | one series |
| `<pool-live-card>` | `.number`, `.stage`, `.assembling`, `.closesBy` | one round being built or assembling |
| `<pool-round-card>` | `.record`, `.explorer` | one mined round |

The two cards take their data as properties. A host drives them from the feed:

```js
const live = document.querySelector('pool-live-card');
feed.subscribe((s) => {
  const r = s.live?.rounds?.[0];
  if (r) { live.number = r.number; live.stage = r.stage; }
});
```

A host that shows the feed's figures in its own markup can use the dashboard's formatting (`count`, `sats`, `bsv`, `duration`, `countdown`, `timeOfDay`, `networkName`, and `dash` for a missing figure), and must set them as text (`textContent`).

Every string from the API is rendered as text, never as markup.

## Theme

These custom properties are the elements' whole theming contract. They inherit into the shadow roots, so a host sets them on `:root` (or on any ancestor), after `tokens.css` if it imports the defaults.

| Property | What it colours or sizes |
|---|---|
| `--pool-bg` | the dashboard page's own background; no element uses it |
| `--pool-surface` | cards and tiles |
| `--pool-text` | text |
| `--pool-muted` | labels and secondary text |
| `--pool-border` | card borders, chart grid |
| `--pool-accent` | links, the chart's line |
| `--pool-done` | a finished stage |
| `--pool-active` | the stage in progress |
| `--pool-warn-bg`, `--pool-warn-text` | `pool-dashboard`'s "cannot reach the pool" and stale notices |
| `--pool-radius` | corner radius of cards and tiles |
| `--pool-card-width` | width of a round card |
| `--pool-font` | text |
| `--pool-mono` | txids and figures set in monospace |

`tokens.css` defines a light and a dark set, following `prefers-color-scheme` and `data-theme="light|dark"` on the root element. Padding and type sizes inside a card are the elements' own.
