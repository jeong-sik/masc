import { defineConfig } from 'vite'
import preact from '@preact/preset-vite'

const proxyTarget = process.env.MASC_DASHBOARD_PROXY_TARGET || 'http://localhost:8935'

export default defineConfig({
  plugins: [preact()],
  base: '/dashboard/',
  build: {
    outDir: '../assets/dashboard',
    emptyOutDir: true,
    rollupOptions: {
      output: {
        manualChunks: {
          vendor: ['preact', 'preact/hooks', 'htm', '@preact/signals'],
        },
      },
    },
  },
  server: {
    proxy: {
      '/api': proxyTarget,
      '/sse': {
        target: proxyTarget,
        // SSE needs no WebSocket upgrade
      },
    },
  },
})
