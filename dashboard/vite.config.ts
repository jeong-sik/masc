import { defineConfig, type Plugin } from 'vite'
import preact from '@preact/preset-vite'
import solid from 'vite-plugin-solid'
import tailwindcss from '@tailwindcss/vite'
import { visualizer } from 'rollup-plugin-visualizer'

const dashboardBasePath = '/dashboard/'
const dashboardEntryHtml = 'index.html'
const dashboardVendorChunkName = 'vendor'

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

function dashboardAssetHref(fileName: string): string {
  return `${dashboardBasePath}${fileName}`
}

function htmlAttributeValue(tag: string, attributeName: string): string | null {
  const match = tag.match(new RegExp(`\\s${attributeName}\\s*=\\s*(["'])(.*?)\\1`, 'i'))
  return match?.[2] ?? null
}

function filterGeneratedModulePreloads(html: string, allowedHrefs: ReadonlySet<string>): string {
  return html.replace(/<link\b[^>]*>/gi, tag => {
    if (htmlAttributeValue(tag, 'rel') !== 'modulepreload') return tag
    const href = htmlAttributeValue(tag, 'href')
    return href && allowedHrefs.has(href) ? tag : ''
  })
}

function dashboardModulePreloadContractPlugin(): Plugin {
  return {
    name: 'masc-dashboard-modulepreload-contract',
    enforce: 'post',
    generateBundle(_options, bundle) {
      const allowedPreloadHrefs = new Set<string>()
      for (const output of Object.values(bundle)) {
        if (output.type === 'chunk' && output.name === dashboardVendorChunkName) {
          allowedPreloadHrefs.add(dashboardAssetHref(output.fileName))
        }
      }

      if (allowedPreloadHrefs.size !== 1) {
        this.error(`Expected exactly one ${dashboardVendorChunkName} chunk for dashboard HTML preloads.`)
      }

      const htmlAsset = bundle[dashboardEntryHtml]
      if (!htmlAsset || htmlAsset.type !== 'asset') {
        this.error(`Expected Vite to emit ${dashboardEntryHtml}.`)
      }

      const html =
        typeof htmlAsset.source === 'string'
          ? htmlAsset.source
          : Buffer.from(htmlAsset.source).toString('utf8')
      htmlAsset.source = filterGeneratedModulePreloads(html, allowedPreloadHrefs)
    },
  }
}

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
      dashboardModulePreloadContractPlugin(),
    ],
    base: dashboardBasePath,
    build: {
      outDir: '../assets/dashboard',
      emptyOutDir: true,
      // 'hidden' produces .map files but omits the sourceMappingURL
      // comment from JS, so browsers don't auto-fetch maps. Maps stay
      // available for manual attach via DevTools "Add source map" or
      // out-of-band tooling. Cuts the deployment artifact (Docker image
      // copy step) from ~30 MB to ~7.3 MB without losing debug coverage.
      sourcemap: 'hidden',
      modulePreload: {
        // MASC dashboard targets the operator's modern browser runtime.
        polyfill: false,
      },
      rollupOptions: {
        output: {
          // Keep manual chunk assignments explicit so Rollup does not merge
          // runtime/helper dependencies into feature chunks. This avoids
          // matching Vite/Rollup private virtual module ids.
          onlyExplicitManualChunks: true,
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
            if (chunkByPackage(normalizedId, ['preact', 'htm', '@preact/signals', '@preact/signals-core'])) {
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
            '/ws': { target: proxyTarget, ws: true },
            '/yjs': { target: proxyTarget, ws: true },
          },
        }
      : undefined,
  }
})
