import path from 'node:path'
import { defineConfig } from 'vite'
import preact from '@preact/preset-vite'

export default defineConfig(({ command }) => {
  const proxyTarget = process.env.MASC_DASHBOARD_PROXY_TARGET
  if (command === 'serve' && !proxyTarget) {
    throw new Error('MASC_DASHBOARD_PROXY_TARGET is required for `vite serve`.')
  }

  return {
    plugins: [preact()],
    base: '/dashboard/',
    build: {
      outDir: '../assets/dashboard',
      emptyOutDir: true,
      rollupOptions: {
        output: {
          entryFileNames: 'assets/[name].js',
          chunkFileNames: 'assets/[name].js',
          assetFileNames: assetInfo => {
            const sourceName = assetInfo.name ?? 'asset'
            const ext = path.extname(sourceName)
            const base = path.basename(sourceName, ext)
            return `assets/${base}${ext}`
          },
          manualChunks(id) {
            if (id.includes('/node_modules/preact/') || id.includes('/node_modules/htm/') || id.includes('/node_modules/@preact/signals/')) {
              return 'vendor'
            }
            if (id.includes('/node_modules/mermaid/')) {
              return 'mermaid.core'
            }
            if (id.includes('/node_modules/cytoscape/')) {
              return 'cytoscape.esm'
            }
            if (id.includes('/node_modules/katex/')) {
              return 'katex'
            }
            return undefined
          },
        },
      },
    },
    server: proxyTarget
      ? {
          proxy: {
            '/api': proxyTarget,
            '/sse': {
              target: proxyTarget,
            },
          },
        }
      : undefined,
  }
})
