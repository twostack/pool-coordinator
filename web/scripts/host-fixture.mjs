// A host page for the browser checks of `pool-elements`: packs the package,
// installs the tarball into an empty project, and builds a page that themes
// the elements with its own `--pool-*` values and feeds them from
// `/api/testnet`, the way the edge site does. Then serves it.
//
//   node scripts/host-fixture.mjs [port]
import { execFileSync, spawn } from 'node:child_process';
import { mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const web = new URL('..', import.meta.url).pathname;
const root = resolve(web, '.host-fixture');
const port = process.argv[2] ?? '4174';

rmSync(root, { recursive: true, force: true });
mkdirSync(root, { recursive: true });
const out = execFileSync('node', ['scripts/pack-elements.mjs', root], { cwd: web, encoding: 'utf8' });
const tarball = out.trim().split('\n').at(-1);

writeFileSync(resolve(root, 'package.json'), JSON.stringify({
  name: 'host-fixture', private: true, type: 'module',
  dependencies: { 'pool-elements': `file:${tarball}` },
}, null, 2));
execFileSync('npm', ['install', '--no-audit', '--no-fund', '--prefer-offline'], { cwd: root, stdio: 'inherit' });

writeFileSync(resolve(root, 'index.html'), `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>host fixture</title>
    <script type="module" src="/main.js"></script>
  </head>
  <body>
    <pool-live-card></pool-live-card>
    <pool-stats></pool-stats>
    <pool-rounds></pool-rounds>
    <pool-chart metric="rounds" label="Rounds mined" bars></pool-chart>
  </body>
</html>
`);
// the host's theme comes after the package's defaults, as a site's would
writeFileSync(resolve(root, 'host.css'), `:root {
  --pool-surface: rgb(244, 246, 241);
  --pool-muted: rgb(88, 102, 108);
  --pool-accent: rgb(36, 95, 99);
  --pool-mono: 'Courier New', monospace;
  --pool-font: Georgia, serif;
  --pool-radius: 4px;
}
`);
writeFileSync(resolve(root, 'main.js'), `import 'pool-elements/tokens.css';
import './host.css';
import * as elements from 'pool-elements';

const feed = new elements.PoolFeed(elements.browserDeps('/api/testnet'));
for (const el of document.querySelectorAll('pool-stats, pool-rounds, pool-chart')) el.feed = feed;
const live = document.querySelector('pool-live-card');
feed.subscribe((s) => {
  const r = s.live?.rounds?.[0];
  if (r) { live.number = r.number; live.stage = r.stage; }
});
window.poolExports = Object.keys(elements).sort();
void feed.start();
`);

const vite = resolve(web, 'node_modules/.bin/vite');
execFileSync(vite, ['build', root, '--outDir', resolve(root, 'dist'), '--emptyOutDir'], { cwd: root, stdio: 'inherit' });
spawn(vite, ['preview', root, '--outDir', resolve(root, 'dist'), '--host', '127.0.0.1', '--port', port, '--strictPort'], { cwd: root, stdio: 'inherit' });
