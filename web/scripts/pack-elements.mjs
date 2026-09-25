// Builds the `pool-elements` package and packs it as a tarball a host page
// installs: the elements' module (vite.lib.config.ts), their type
// declarations, and tokens.css, the default `--pool-*` theme. The version is
// pool-coordinator's own (pubspec.yaml), or VERSION when the release names it.
//
//   node scripts/pack-elements.mjs [destination directory]
import { execFileSync } from 'node:child_process';
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

const web = new URL('..', import.meta.url).pathname;
const pkgDir = resolve(web, 'pool-elements');
const dest = resolve(process.argv[2] ?? pkgDir);

const pubspec = readFileSync(resolve(web, '../pubspec.yaml'), 'utf8');
const version = process.env.VERSION ?? /^version:\s*(\S+)/m.exec(pubspec)?.[1];
if (!version) throw new Error('no version: set VERSION or give pubspec.yaml one');

const run = (cmd, args) => execFileSync(cmd, args, { cwd: web, stdio: 'inherit' });
run('npx', ['vite', 'build', '--config', 'vite.lib.config.ts']);
run('npx', ['tsc', '-p', 'tsconfig.lib.json']);
copyFileSync(resolve(web, 'src/tokens.css'), resolve(pkgDir, 'dist/tokens.css'));

const manifest = JSON.parse(readFileSync(resolve(pkgDir, 'package.json'), 'utf8'));
manifest.version = version;
writeFileSync(resolve(pkgDir, 'package.json'), JSON.stringify(manifest, null, 2) + '\n');

mkdirSync(dest, { recursive: true });
execFileSync('npm', ['pack', '--pack-destination', dest], { cwd: pkgDir, stdio: 'inherit' });
// back to the placeholder, so a pack leaves the tree as it found it
manifest.version = '0.0.0';
writeFileSync(resolve(pkgDir, 'package.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log(`${dest}/pool-elements-${version}.tgz`);
