import { defineConfig } from 'vite'
import preact from '@preact/preset-vite'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig(({ command }) => {
  const proxyTarget = process.env.MASC_DASHBOARD_PROXY_TARGET
  if (command === 'serve' && !proxyTarget) {
    throw new Error('MASC_DASHBOARD_PROXY_TARGET is required for `vite serve`.')
  }

  return {
    plugins: [tailwindcss(), preact()],
    base: '/dashboard/',
    build: {
      outDir: '../assets/dashboard',
      emptyOutDir: true,
      sourcemap: true,
      rollupOptions: {
        output: {
          manualChunks: {
            vendor: ['preact', 'preact/hooks', 'htm', '@preact/signals'],
          },
        },
      },
    },
    server: proxyTarget
      ? {
          proxy: {
            '/api': { target: proxyTarget, changeOrigin: true },
            '/mcp': { target: proxyTarget, changeOrigin: true },
            '/sse': { target: proxyTarget, changeOrigin: true },
          },
        }
      : undefined,
  }
})
