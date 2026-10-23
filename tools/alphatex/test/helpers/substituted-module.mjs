import { readFile } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'

const namedImport = /^import \{([^}]*)\} from '([^']+)'$/
const importStatement = /^\s*import[\s{*'"]/

// Load a terminal view with its imports replaced by name.
//
// A binding from a relative import is the real module's export unless the
// test substitutes it, so an import added to the view does not break a test.
// A real relative module keeps its own real imports: a test fakes each entry
// point that would open a process, file or device on a path it drives. A
// binding from a builtin or package must be substituted, so the view itself
// never reaches one through a forgotten name.
//
// Every imported name must exist in its module and be imported once, as the
// real link would require. A substitute the view does not import is refused,
// so a misspelt or stale fake cannot leave the real export running; names the
// view uses without importing them (globals it shadows, names a rewrite adds)
// go in `globals`. An import form other than one-line top-level named imports
// is refused rather than guessed.
//
// `rewrite` edits the source after its imports are removed, for example to
// replace a dynamic import with a substitute.
export async function loadSubstituted(url, substitutes, { globals = {}, rewrite = source => source } = {}) {
  const source = await readFile(url, 'utf8')
  const real = {}, imported = new Set(), unsubstituted = []
  for (const line of source.split('\n').filter(text => importStatement.test(text))) {
    const match = namedImport.exec(line)
    if (!match) throw new Error(`Unsupported import form in ${url}: ${line.trim()}`)
    const [, names, specifier] = match
    const relative = specifier.startsWith('.')
    const module = await import(relative ? new URL(specifier, url) : specifier)
    for (const name of names.split(',').map(value => value.trim()).filter(Boolean)) {
      const [exported, local = exported] = name.split(/\s+as\s+/)
      if (!Object.hasOwn(module, exported)) throw new Error(`${specifier} has no export ${exported}`)
      if (imported.has(local)) throw new Error(`${url} imports ${local} twice`)
      imported.add(local)
      if (Object.hasOwn(substitutes, local)) continue
      if (relative) real[local] = module[exported]
      else unsubstituted.push(`${local} from ${specifier}`)
    }
  }
  if (unsubstituted.length) throw new Error(`Substitute ${unsubstituted.join(', ')}`)
  const stray = Object.keys(substitutes).filter(name => !imported.has(name))
  if (stray.length) throw new Error(`${url} does not import ${stray.join(', ')}; pass names it uses without importing as globals`)
  const slot = `substituted-${randomUUID()}`
  globalThis[slot] = { ...real, ...substitutes, ...globals }
  try {
    // The prefix binds every name once, when the module evaluates.
    const prefix = `const {${Object.keys(globalThis[slot]).join(',')}} = globalThis[${JSON.stringify(slot)}];\n`
    const body = rewrite(source.replace(/^import \{[^}]*\} from '[^']+'$/gm, ''))
    return await import('data:text/javascript;base64,' + Buffer.from(prefix + body).toString('base64'))
  } finally {
    delete globalThis[slot]
  }
}
