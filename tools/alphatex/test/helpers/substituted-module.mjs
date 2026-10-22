import { readFile } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'

const namedImport = /^import \{([^}]*)\} from '([^']+)'$/

// Load a terminal view with its imports replaced by name.
//
// A binding from a relative import is the real module's export unless the
// test substitutes it, so a test lists only the names it fakes and an import
// added to the view does not break it. A binding from a builtin or package
// must be substituted: the test then never opens a process, file or device
// through a name it forgot. An import form other than one-line named imports
// is refused rather than guessed.
//
// `rewrite` edits the source after its imports are removed, for example to
// replace a dynamic import with a substitute.
export async function loadSubstituted(url, substitutes, { rewrite = source => source } = {}) {
  const source = await readFile(url, 'utf8')
  const real = {}
  for (const line of source.split('\n').filter(text => text.startsWith('import'))) {
    const match = namedImport.exec(line)
    if (!match) throw new Error(`Unsupported import form in ${url}: ${line}`)
    const [, names, specifier] = match
    const bindings = names.split(',').map(name => name.trim()).filter(Boolean).map(name => {
      const [imported, local = imported] = name.split(/\s+as\s+/)
      return { imported, local }
    })
    const missing = bindings.filter(({ local }) => !Object.hasOwn(substitutes, local))
    if (!missing.length) continue
    if (!specifier.startsWith('.')) {
      throw new Error(`Substitute ${missing.map(({ local }) => local).join(', ')} from ${specifier}`)
    }
    const module = await import(new URL(specifier, url))
    for (const { imported, local } of missing) {
      if (!Object.hasOwn(module, imported)) throw new Error(`${specifier} has no export ${imported}`)
      real[local] = module[imported]
    }
  }
  const slot = `substituted-${randomUUID()}`
  globalThis[slot] = { ...real, ...substitutes }
  try {
    // The prefix binds every name once, when the module evaluates.
    const prefix = `const {${Object.keys(globalThis[slot]).join(',')}} = globalThis[${JSON.stringify(slot)}];\n`
    const body = rewrite(source.replace(/^import .*$/gm, ''))
    return await import('data:text/javascript;base64,' + Buffer.from(prefix + body).toString('base64'))
  } finally {
    delete globalThis[slot]
  }
}
