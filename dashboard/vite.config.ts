import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { defineConfig, type HtmlTagDescriptor, type Plugin } from 'vite'
import preact from '@preact/preset-vite'
import tailwindcss from '@tailwindcss/vite'
import { sourceContextPlugin } from './dev/source-context-plugin'
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

// Emit the marker with the bundle itself: pnpm build, Docker, and the shell
// wrapper all run Vite, whose emptyOutDir removes any previous marker.
// Time is diagnostic; source identity is declared only for a clean checkout.
function dashboardBuildStampPlugin(): Plugin {
  const cwd = fileURLToPath(new URL('..', import.meta.url))
  const cleanSourceCommit = (): string | null => {
    try {
      const git = (...args: string[]) => execFileSync('git', args, { cwd, encoding: 'utf8' }).trim()
      return git('status', '--porcelain', '--untracked-files=normal') === ''
        ? git('rev-parse', 'HEAD') : null
    } catch {
      return null
    }
  }
  let startedFrom: string | null = null
  return {
    apply: 'build',
    name: 'masc-dashboard-build-stamp',
    buildStart() {
      startedFrom = cleanSourceCommit()
    },
    generateBundle() {
      const sourceCommit = startedFrom === cleanSourceCommit() ? startedFrom : null
      this.emitFile({
        type: 'asset',
        fileName: '.build-identity.json',
        source: `${JSON.stringify({ schema: 'masc.dashboard-build.v1', source_commit: sourceCommit })}\n`,
      })
      this.emitFile({
        type: 'asset',
        fileName: '.build-stamp',
        source: `${new Date().toISOString()}\n`,
      })
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
      sourceContextPlugin(),
      tailwindcss(),
      preact(),
      ...reportPlugins,
      dashboardModulePreloadContractPlugin(),
      dashboardBuildStampPlugin(),
    ],
    base: dashboardBasePath,
    build: {
      outDir: '../assets/dashboard',
      emptyOutDir: true,
      sourcemap: 'hidden',
      modulePreload: {
        resolveDependencies(_url, deps, { hostType }) {
          if (hostType === 'html') return []
          return deps
        },
        polyfill: false,
      },
      rollupOptions: {
        output: {
          onlyExplicitManualChunks: true,
          manualChunks(id) {
            const normalizedId = normalizeModuleId(id)
            if (chunkByPackage(normalizedId, ['preact', 'htm', '@preact/signals', '@preact/signals-core'])) {
              return 'vendor'
            }
            if (chunkByPackage(normalizedId, ['lucide-preact'])) {
              return 'icons'
            }
            if (chunkByPackage(normalizedId, ['uplot'])) {
              return 'charts'
            }
            if (chunkByPackage(normalizedId, ['@tanstack/preact-table', '@tanstack/table-core', '@tanstack/virtual-core'])) {
              return 'table'
            }
            if (chunkByPackage(normalizedId, ['marked', 'dompurify', 'diff'])) {
              return 'markdown'
            }
            return undefined
          },
        },
      },
    },
    server: proxyTarget
      ? {
          proxy: {
            '/health': proxyTarget,
            '/api': proxyTarget,
            '/mcp': { target: proxyTarget, changeOrigin: true },
            '/sse': { target: proxyTarget },
            '/ws': {
              target: proxyTarget,
              ws: true,
              changeOrigin: true,
              configure(proxy) {
                proxy.on('proxyReqWs', (proxyReq, req, socket) => {
                  const origin = req.headers.origin
                  let sameOrigin = false
                  try {
                    const parsed = new URL(origin ?? '')
                    sameOrigin = (parsed.protocol === 'http:' || parsed.protocol === 'https:')
                      && parsed.host === req.headers.host
                  } catch { /* Missing or malformed browser origins are refused. */ }
                  if (!sameOrigin) {
                    proxyReq.destroy()
                    socket.destroy()
                    return
                  }
                  proxyReq.setHeader('origin', new URL(proxyTarget).origin)
                })
              },
            },
          },
        }
      : undefined,
  }
})
