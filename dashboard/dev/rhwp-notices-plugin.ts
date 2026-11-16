import { readFileSync, readdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join, relative } from 'node:path'
import type { Plugin } from 'vite'

/** Ship the notices supplied with the same package as the lazy HWP WASM asset. */
export function rhwpNoticesPlugin(): Plugin {
  const require = createRequire(import.meta.url)
  const root = dirname(require.resolve('@rhwp/core/package.json'))
  function files(directory: string): string[] {
    return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
      const path = join(directory, entry.name)
      return entry.isDirectory() ? files(path) : entry.isFile() ? [path] : []
    })
  }
  return {
    name: 'rhwp-notices',
    apply: 'build',
    generateBundle() {
      for (const path of [join(root, 'LICENSE'), ...files(join(root, 'notices'))]) {
        this.emitFile({ type: 'asset', fileName: `assets/licenses/rhwp/${relative(root, path).split('\\').join('/')}`, source: readFileSync(path) })
      }
    },
  }
}
