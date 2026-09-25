// The dashboard's elements as a package a host page embeds: importing this
// module registers the elements, and the host feeds them from one PoolFeed
// (`pool-live-card` and `pool-round-card` take their data as properties; a
// host drives them from `feed.subscribe`). The elements take their theme
// from the `--pool-*` properties (tokens.css holds the defaults), and ask for
// nothing but the API base the feed is given.
//
//   import { PoolFeed, browserDeps } from 'pool-elements';
//   import 'pool-elements/tokens.css';
//   const feed = new PoolFeed(browserDeps('/api/testnet'));
//   document.querySelector('pool-stats').feed = feed;
//   void feed.start();
export { PoolChart } from './elements/pool-chart';
export { PoolConnect, connectBlocks, walletConnect, type CloakNetwork, type ConnectBlocks, type WalletConnect } from './elements/pool-connect';
export { PoolDashboard, networkName } from './elements/pool-dashboard';
export { PoolLiveCard } from './elements/pool-live-card';
export { PoolRoundCard } from './elements/pool-round-card';
export { PoolRounds } from './elements/pool-rounds';
export { PoolStats } from './elements/pool-stats';
export { PoolFeed, browserDeps, type FeedDeps, type FeedState } from './feed';
// the dashboard's own formatting, for a host that shows the feed's figures itself
export { bsv, count, countdown, dash, duration, sats, timeOfDay } from './format';
export type * from './api';
