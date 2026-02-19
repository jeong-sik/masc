import { defineConfig } from 'vite'
import preact from '@preact/preset-vite'

export default defineConfig({
  plugins: [preact()],
  base: '/dashboard/',
  build: {
    outDir: '../assets/dashboard',
    emptyOutDir: true,
  },
  server: {
    proxy: {
      '/api': 'http://localhost:8935',
      '/sse': {
        target: 'http://localhost:8935',
        // SSE needs no WebSocket upgrade
      },
    },
  },
})
