import { defineConfig } from 'vite'
import preact from '@preact/preset-vite'
import solid from 'vite-plugin-solid'
import tailwindcss from '@tailwindcss/vite'
import { visualizer } from 'rollup-plugin-visualizer'

function normalizeModuleId(id: string): string {
  return id.replace(/\\/g, '/')
}

function chunkByPackage(id: string, packageNames: string[]): boolean {
  return packageNames.some(packageName =>
    id.includes(`/node_modules/${packageName}/`),
  )
}

const heavyMermaidDependencyChunks: Array<{ packages: string[]; chunk: string }> = [
  {
    packages: ['cytoscape'],
    chunk: 'cytoscape',
  },
  {
    packages: ['cytoscape-cose-bilkent', 'cose-base', 'layout-base'],
    chunk: 'mermaid-cose-layout',
  },
  {
    packages: ['@mermaid-js/parser'],
    chunk: 'mermaid-parser',
  },
  {
    packages: ['langium'],
    chunk: 'mermaid-parser-langium',
  },
  {
    packages: ['chevrotain', 'chevrotain-allstar', '@chevrotain/regexp-to-ast'],
    chunk: 'mermaid-parser-chevrotain',
  },
  {
    packages: [
      'vscode-jsonrpc',
      'vscode-languageserver-protocol',
      'vscode-languageserver-types',
    ],
    chunk: 'mermaid-parser-vscode-lsp',
  },
]

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
    plugins: [
      tailwindcss(),
      // SolidJS plugin must run before Preact's so it claims its files
      // first. The `include` regex restricts Solid's JSX transform to
      // headless-solid/ adapters and preview/solid-* pages — the rest of
      // the app (src/, headless-preact/, all other previews) stays Preact.
      // PoC scope per RFC 0017.
      solid({
        include: [
          /design-system\/headless-solid\//,
          /design-system\/preview\/solid-.*/,
          /src\/components\/.*\.solid(\.test)?\.(ts|tsx)$/,
        ],
      }),
      preact(),
      ...reportPlugins,
    ],
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
          manualChunks(id) {
            const normalizedId = normalizeModuleId(id)
            for (const { packages, chunk } of heavyMermaidDependencyChunks) {
              if (chunkByPackage(normalizedId, packages)) return chunk
            }
            if (normalizedId.includes('/node_modules/mermaid/dist/chunks/mermaid.core/')) {
              const filename = normalizedId
                .slice(normalizedId.lastIndexOf('/') + 1)
                .replace(/\.mjs$/, '')
              return `mermaid-${filename}`
            }
            if (normalizedId.includes('/node_modules/mermaid/dist/mermaid.core.mjs')) {
              return 'mermaid-core'
            }
            if (chunkByPackage(normalizedId, ['preact', 'htm', '@preact/signals'])) {
              return 'vendor'
            }
            if (chunkByPackage(normalizedId, ['solid-js'])) {
              return 'solid'
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
            '/mcp': { target: proxyTarget },
            '/sse': { target: proxyTarget },
            '/ws': { target: proxyTarget },
            '/yjs': { target: proxyTarget, ws: true },
          },
        }
      : undefined,
  }
})
