import './theme.css';
import './elements/pool-dashboard';
import './elements/pool-connect';
import { PoolFeed, browserDeps } from './feed';

const feed = new PoolFeed(browserDeps());
const page = document.querySelector('pool-dashboard');
if (page !== null) page.feed = feed;
const connect = document.querySelector('pool-connect');
if (connect !== null) connect.feed = feed;
void feed.start();
