// Compiles the dashboard's full stylesheet set (parsed from src/main.ts, so the
// harness cannot drift from the app) into one static CSS file via Vite, which
// is required because global.css pulls Tailwind and tokens.generated.css uses
// @theme. The output is what the parity page links, letting the prototype's raw
// JSX keep loading from a plain static server.
import { readFileSync, writeFileSync, readdirSync, rmSync, mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'vite'
import tailwindcss from '@tailwindcss/vite'

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const stylesDir = resolve(root, 'src/styles')
const mainTs = readFileSync(resolve(root, 'src/main.ts'), 'utf8')

const imports = []
for (const line of mainTs.split('\n')) {
  const m = line.match(/^import '(\.\/styles\/[^']+\.css)'/)
  if (m) { imports.push(m[1].replace('./styles/', './src/styles/')); continue }
  if (line.includes("import.meta.glob('./styles/*-v2.css'")) {
    readdirSync(stylesDir).filter(f => f.endsWith('-v2.css')).sort()
      .forEach(f => imports.push(`./src/styles/${f}`))
  }
}
if (imports.length < 20) throw new Error(`parsed only ${imports.length} stylesheets from main.ts`)

const entry = resolve(root, '.parity-styles-entry.js')
writeFileSync(entry, imports.map(p => `import '${p}'`).join('\n') + '\n')
const outDir = resolve(root, '.parity-css')
rmSync(outDir, { recursive: true, force: true })
await build({
  root, configFile: false, logLevel: 'warn',
  plugins: [tailwindcss()],
  build: { outDir, emptyOutDir: true, cssCodeSplit: false, rollupOptions: { input: entry, output: { assetFileNames: 'parity.[ext]' } } },
})
rmSync(entry)
mkdirSync(resolve(root, 'prototypes/keeper-v2/_parity'), { recursive: true })
// The app resolves fonts from the Vite base (/dashboard/assets/fonts/...);
// the parity page is served from a plain static server rooted at dashboard/,
// so point the URL at the same file on disk. Same font, same bytes.
const css = readFileSync(resolve(outDir, 'parity.css'), 'utf8')
  .replaceAll('/dashboard/assets/fonts/', '../../../public/assets/fonts/')
writeFileSync(resolve(root, 'prototypes/keeper-v2/_parity/dashboard.css'), css)
console.log(`compiled ${imports.length} stylesheets -> prototypes/keeper-v2/_parity/dashboard.css`)
