import './theme.css';
import './elements/pool-dashboard';
import { PoolFeed, browserDeps } from './feed';

const feed = new PoolFeed(browserDeps());
const page = document.querySelector('pool-dashboard');
if (page !== null) page.feed = feed;
void feed.start();
