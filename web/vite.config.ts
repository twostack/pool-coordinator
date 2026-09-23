/// <reference types="vitest/config" />
import { defineConfig } from 'vite';

// The site is static files with no runtime of its own: `vite build` writes
// them to dist/, which the proxy serves. In development the API is proxied
// to a coordinator on its default loopback port, so the page runs against a
// localnet pool unchanged.
export default defineConfig({
  build: {
    target: 'es2022',
    // No inline data: the content security policy allows the page's own
    // origin only, so every asset is a file.
    assetsInlineLimit: 0,
  },
  server: {
    proxy: { '/api': process.env.POOL_API ?? 'http://127.0.0.1:8787' },
  },
  test: {
    environment: 'happy-dom',
    include: ['test/**/*.test.ts'],
  },
});
