// Build the standalone "Keeper Agent v2" design prototype into the dashboard
// output tree at assets/dashboard/v2/.
//
// Why a separate build instead of a Vite entry: the prototype's ~20 .jsx files
// have no import/export — they share one global scope across ordered classic
// <script> tags (each top-level `const Roster`/`KEEPERS`/`useDock` is visible to
// the next file). Vite/ESM gives each module its own scope, which would break
// that sharing, and @preact/preset-vite rewrites `react` -> `preact/compat`
// globally, which conflicts with a faithful React-18 port. So this script keeps
// the prototype's exact model: pre-transpile each .jsx to a classic .js (only
// removing the in-browser Babel step) and let index.html load them in order
// against the React 18 UMD globals. Output lands in the gitignored
// assets/dashboard/ tree; run after `vite build` (which empties that dir).
import { transformWithEsbuild } from 'vite'
import { readFile, writeFile, mkdir, copyFile, readdir, rm } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const dashboardDir = join(scriptDir, '..')
const srcDir = join(dashboardDir, 'v2')
const outDir = join(dashboardDir, '..', 'assets', 'dashboard', 'v2')
const portraitSrc = join(dashboardDir, 'public', 'assets', 'keepers', 'portraits')

// Convert top-level `const`/`let` -> `var` in esbuild output.
//
// The files share one global lexical scope across ordered classic <script> tags
// and several re-declare the same top-level binding (e.g. `const { useState } =
// React` appears in many files). Across scripts that is a "Identifier already
// declared" SyntaxError that kills the whole second file. `var` allows
// redeclaration and still attaches to the global object, preserving the
// cross-file sharing the prototype depends on. The in-browser Babel the
// prototype used did this via its block-scoping transform; esbuild cannot lower
// const/let, so we do it ourselves — but ONLY at the top level.
//
// esbuild always emits top-level statements at column 0 and indents nested code,
// so anchoring on line-start `const`/`let` rewrites exactly the global bindings
// while leaving every nested (indented) const/let and every `for (let …)` head
// untouched — block scoping inside functions/loops is preserved.
function topLevelConstToVar(code) {
  return code.replace(/^(?:const|let)\b/gm, 'var')
}

// Load order — must match index.html. The shared global scope makes order load-bearing.
const SCRIPTS = [
  'primitives', 'molecules', 'organisms-2', 'organisms-5', 'perf', 'tweaks-panel',
  'data', 'data-surfaces', 'messages', 'turn-inspector', 'rails', 'overview',
  'work', 'board', 'connectors', 'settings', 'ide', 'composer', 'dock', 'app',
]

async function main() {
  await rm(outDir, { recursive: true, force: true })
  await mkdir(join(outDir, 'styles'), { recursive: true })
  await mkdir(join(outDir, 'assets', 'portraits'), { recursive: true })

  // 1. Transpile each .jsx -> classic .js (JSX only; no bundling, no module wrap).
  for (const name of SCRIPTS) {
    const srcPath = join(srcDir, `${name}.jsx`)
    const code = await readFile(srcPath, 'utf8')
    const result = await transformWithEsbuild(code, srcPath, {
      loader: 'jsx',
      jsx: 'transform',
      jsxFactory: 'React.createElement',
      jsxFragment: 'React.Fragment',
      format: undefined, // keep top-level decls global for classic <script> sharing
      sourcemap: false,
    })
    await writeFile(join(outDir, `${name}.js`), topLevelConstToVar(result.code), 'utf8')
  }

  // 2. CSS.
  const styles = await readdir(join(srcDir, 'styles'))
  for (const css of styles.filter(f => f.endsWith('.css'))) {
    await copyFile(join(srcDir, 'styles', css), join(outDir, 'styles', css))
  }

  // 3. Portraits — reuse the repo's existing keeper portraits (don't commit copies).
  const portraits = await readdir(portraitSrc)
  for (const png of portraits.filter(f => f.endsWith('.png'))) {
    await copyFile(join(portraitSrc, png), join(outDir, 'assets', 'portraits', png))
  }

  // 4. Entry HTML.
  await copyFile(join(srcDir, 'index.html'), join(outDir, 'index.html'))

  console.log(`build-v2: ${SCRIPTS.length} scripts, ${styles.length} styles, ${portraits.length} portraits -> ${outDir}`)
}

main().catch((err) => {
  console.error('build-v2 failed:', err)
  process.exit(1)
})
