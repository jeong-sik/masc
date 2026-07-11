import { defineConfig, type HtmlTagDescriptor, type Plugin } from 'vite'
import preact from '@preact/preset-vite'
import tailwindcss from '@tailwindcss/vite'
import { visualizer } from 'rollup-plugin-visualizer'

const dashboardBasePath = '/dashboard/'
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

function dashboardVendorPreloadTag(fileName: string): HtmlTagDescriptor {
  return {
    tag: 'link',
    attrs: {
      crossorigin: '',
      href: dashboardAssetHref(fileName),
      rel: 'modulepreload',
    },
    injectTo: 'head',
  }
}

function dashboardModulePreloadContractPlugin(): Plugin {
  return {
    apply: 'build',
    name: 'masc-dashboard-modulepreload-contract',
    enforce: 'post',
    transformIndexHtml: {
      order: 'post',
      handler(_html, ctx) {
        const bundle = ctx.bundle
        if (!bundle) {
          this.error('Expected Vite to provide the dashboard output bundle while transforming index.html.')
        }

        const vendorChunkFiles: string[] = []
        for (const output of Object.values(bundle)) {
          if (output.type === 'chunk' && output.name === dashboardVendorChunkName) {
            vendorChunkFiles.push(output.fileName)
          }
        }

        if (vendorChunkFiles.length !== 1) {
          this.error(`Expected exactly one ${dashboardVendorChunkName} chunk for dashboard HTML preloads.`)
        }

        const vendorChunkFile = vendorChunkFiles[0]
        if (!vendorChunkFile) {
          this.error(`Expected a file name for the ${dashboardVendorChunkName} chunk.`)
        }

        return [dashboardVendorPreloadTag(vendorChunkFile)]
      },
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
        // Vite's automatic HTML preloads are all-or-nothing here; the
        // build hook below injects the single manifest-derived vendor tag.
        resolveDependencies(_url, deps, { hostType }) {
          if (hostType === 'html') return []
          return deps
        },
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
