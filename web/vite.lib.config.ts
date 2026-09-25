import { defineConfig } from 'vite';

// The elements as a package (`pool-elements`) for a host page, beside the
// single-page build of vite.config.ts. Lit and uPlot are bundled in, so a
// host installs one tarball and loads one module from its own origin.
export default defineConfig({
  publicDir: false,
  build: {
    target: 'es2022',
    outDir: 'pool-elements/dist',
    emptyOutDir: true,
    assetsInlineLimit: 0,
    // tokens.css is copied beside it by scripts/pack-elements.mjs: it is
    // plain CSS, and a library build takes no CSS entry
    lib: {
      entry: 'src/lib.ts',
      formats: ['es'],
      fileName: () => 'index.js',
    },
  },
});
