import { defineConfig, devices } from '@playwright/test';

// Browser checks run against the built site served by `vite preview`, with
// the API faked per test by request routing, so they need no coordinator.
// The end-to-end run through the proxy sets POOL_SITE to its origin
// instead and starts nothing here.
const site = process.env.POOL_SITE;

export default defineConfig({
  testDir: 'e2e',
  timeout: 30_000,
  use: {
    baseURL: site ?? 'http://127.0.0.1:4173',
    ignoreHTTPSErrors: true,
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  ...(site ? {} : {
    webServer: {
      command: 'npm run build && npx vite preview --host 127.0.0.1 --port 4173 --strictPort',
      url: 'http://127.0.0.1:4173',
      reuseExistingServer: false,
      timeout: 120_000,
    },
  }),
});
