// The payload budget: the page's first load, every file in dist/ that the
// browser fetches for it, must stay under 150 KB gzipped. Everything the
// build writes is counted, so a file loaded later still counts against the
// budget rather than slipping past it. Fails the build when over.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { gzipSync } from 'node:zlib';

const budget = 150 * 1024;
const root = new URL('../dist/', import.meta.url).pathname;

function files(dir) {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    return statSync(p).isDirectory() ? files(p) : [p];
  });
}

let total = 0;
for (const f of files(root).sort()) {
  const size = gzipSync(readFileSync(f), { level: 9 }).length;
  total += size;
  console.log(`${(size / 1024).toFixed(1).padStart(7)} KB  ${relative(root, f)}`);
}
const line = `first load ${(total / 1024).toFixed(1)} KB gzipped, budget ${budget / 1024} KB`;
if (total > budget) {
  console.error(`over budget: ${line}`);
  process.exit(1);
}
console.log(line);
