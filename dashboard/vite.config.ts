import { defineConfig } from 'vite'
import preact from '@preact/preset-vite'
import tailwindcss from '@tailwindcss/vite'
import { visualizer } from 'rollup-plugin-visualizer'

export default defineConfig(({ command }) => {
  const proxyTarget = process.env.MASC_DASHBOARD_PROXY_TARGET
  if (command === 'serve' && !proxyTarget) {
    throw new Error('MASC_DASHBOARD_PROXY_TARGET is required for `vite serve`.')
  }

  const bundleReport = process.env.BUNDLE_REPORT === '1'
  const reportPlugins = bundleReport
    ? [
        visualizer({
          filename: '../assets/dashboard/bundle-report.html',
          template: 'treemap',
          gzipSize: true,
          brotliSize: true,
          open: false,
        }),
      ]
    : []

  return {
    plugins: [tailwindcss(), preact(), ...reportPlugins],
    base: '/dashboard/',
    build: {
      outDir: '../assets/dashboard',
      emptyOutDir: true,
      // 'hidden' produces .map files but omits the sourceMappingURL
      // comment from JS, so browsers don't auto-fetch maps. Maps stay
      // available for manual attach via DevTools "Add source map" or
      // out-of-band tooling. Cuts the deployment artifact (Docker image
      // copy step) from ~30 MB to ~7.3 MB without losing debug coverage.
      sourcemap: 'hidden',
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
            '/api': proxyTarget,
            '/mcp': { target: proxyTarget },
            '/sse': { target: proxyTarget },
            '/ws': { target: proxyTarget },
          },
        }
      : undefined,
  }
})
