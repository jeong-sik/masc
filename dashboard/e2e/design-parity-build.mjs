// Builds the skin-parity page: the design prototype's own DOM + mock data,
// restyled by the LIVE dashboard's stylesheet set. Same DOM, same data on both
// sides, so the SSIM delta between this page and the prototype's own
// `Keeper Agent v5.html` is pure CSS drift.
//
// The stylesheet list is parsed out of src/main.ts rather than restated here,
// so the harness cannot drift from what the app actually loads. The page is
// served by Vite (not a static server) because global.css pulls in Tailwind and
// tokens.generated.css uses @theme — both need the build pipeline to resolve.
import { readFileSync, writeFileSync, readdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const protoDir = resolve(here, '../prototypes/keeper-v2')
const stylesDir = resolve(here, '../src/styles')
const mainTs = readFileSync(resolve(here, '../src/main.ts'), 'utf8')

const imports = []
for (const line of mainTs.split('\n')) {
  const m = line.match(/^import '(\.\/styles\/[^']+\.css)'/)
  if (m) { imports.push(m[1].replace('./styles/', '/src/styles/')); continue }
  if (line.includes("import.meta.glob('./styles/*-v2.css'")) {
    // Vite resolves glob keys in sorted order; mirror that.
    readdirSync(stylesDir).filter(f => f.endsWith('-v2.css')).sort()
      .forEach(f => imports.push(`/src/styles/${f}`))
  }
}
if (imports.length < 20) throw new Error(`parsed only ${imports.length} stylesheets from main.ts`)

const src = process.argv[2] ?? 'Keeper Agent v5.html'
const outName = process.argv[3] ?? '_parity-vendored.html'
let html = readFileSync(`${protoDir}/${src}`, 'utf8')
html = html.replace(/[ \t]*<link rel="stylesheet" href="styles\/[^"]+" \/>\n/g, '')
const block = `<link rel="stylesheet" href="_parity/dashboard.css" />\n`
html = html.replace('<link rel="preconnect" href="https://fonts.googleapis.com" />', `${block}<link rel="preconnect" href="https://fonts.googleapis.com" />`)
writeFileSync(`${protoDir}/${outName}`, html)
console.log(`built ${outName}: ${imports.length} stylesheets from main.ts`)
