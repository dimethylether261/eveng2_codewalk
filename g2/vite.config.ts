import { defineConfig } from 'vite'

// Top-level await in main.ts (waitForEvenAppBridge) needs an ES2022 target.
export default defineConfig({
  build: { target: 'es2022' },
})
