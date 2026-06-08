import { Extension } from '@codemirror/state'
import { StreamLanguage, type StringStream, type StreamParser } from '@codemirror/language'

type LanguageModule = () => Promise<{ extension: Extension }>

interface LanguageEntry {
  readonly id: string
  readonly load: LanguageModule
}

interface OcamlStreamState {
  commentDepth: number
  stringQuote: '"' | null
}

const OCAML_KEYWORDS = new Set([
  'and',
  'as',
  'assert',
  'begin',
  'class',
  'constraint',
  'do',
  'done',
  'downto',
  'else',
  'end',
  'exception',
  'external',
  'for',
  'fun',
  'function',
  'functor',
  'if',
  'in',
  'include',
  'inherit',
  'initializer',
  'lazy',
  'let',
  'match',
  'method',
  'module',
  'mutable',
  'new',
  'nonrec',
  'object',
  'of',
  'open',
  'private',
  'rec',
  'sig',
  'struct',
  'then',
  'to',
  'try',
  'type',
  'val',
  'virtual',
  'when',
  'while',
  'with',
])

const OCAML_ATOMS = new Set(['false', 'true', 'None', 'Some', 'Ok', 'Error'])

const OCAML_BUILTINS = new Set([
  'bool',
  'char',
  'exn',
  'float',
  'int',
  'list',
  'option',
  'result',
  'string',
  'unit',
])

const ocamlStreamParser: StreamParser<OcamlStreamState> = {
  name: 'ocaml',
  startState: () => ({ commentDepth: 0, stringQuote: null }),
  copyState: state => ({ ...state }),
  languageData: {
    name: 'ocaml',
    commentTokens: { block: { open: '(*', close: '*)' } },
  },
  token(stream, state) {
    if (state.commentDepth > 0) return readOcamlComment(stream, state)
    if (state.stringQuote !== null) return readOcamlString(stream, state)
    if (stream.eatSpace()) return null

    if (stream.match('(*')) {
      state.commentDepth = 1
      return readOcamlComment(stream, state)
    }

    const ch = stream.next()
    if (ch === undefined) return null

    if (ch === '"') {
      state.stringQuote = '"'
      return readOcamlString(stream, state)
    }

    if (ch === '\'') {
      if (stream.match(/^\\?.'/)) return 'string'
      stream.eatWhile(/[A-Za-z0-9_']/)
      return 'typeName'
    }

    if (/[0-9]/.test(ch)) {
      stream.eatWhile(/[A-Za-z0-9_'.]/)
      return 'number'
    }

    if (/[A-Z]/.test(ch)) {
      stream.eatWhile(/[A-Za-z0-9_']/)
      const ident = stream.current()
      return OCAML_ATOMS.has(ident) ? 'atom' : 'typeName'
    }

    if (/[a-z_]/.test(ch)) {
      stream.eatWhile(/[A-Za-z0-9_']/)
      const ident = stream.current()
      if (OCAML_KEYWORDS.has(ident)) return 'keyword'
      if (OCAML_ATOMS.has(ident)) return 'atom'
      if (OCAML_BUILTINS.has(ident)) return 'standard variableName'
      return 'variableName'
    }

    if (/[-+*/=<>@^|&$%!?~:.;,#]/.test(ch)) {
      stream.eatWhile(/[-+*/=<>@^|&$%!?~:.;,#]/)
      return 'operator'
    }

    return null
  },
}

const ocamlLanguage = StreamLanguage.define(ocamlStreamParser)

// ── TOML StreamLanguage ──────────────────────────────

interface TomlStreamState {
  readonly inSection: boolean
}

const tomlStreamParser: StreamParser<TomlStreamState> = {
  name: 'toml',
  startState: () => ({ inSection: false }),
  copyState: state => ({ ...state }),
  languageData: {
    name: 'toml',
    commentTokens: { line: '#' },
  },
  token(stream, state) {
    if (stream.eatSpace()) return null

    if (stream.sol() && stream.peek() === '#') {
      stream.skipToEnd()
      return 'comment'
    }

    if (stream.sol() && stream.peek() === '[') {
      stream.skipToEnd()
      return 'heading'
    }

    if (stream.peek() === '=') {
      stream.next()
      return 'operator'
    }

    if (stream.peek() === '"' || stream.peek() === '\'') {
      const quote = stream.next()!
      let escaped = false
      while (!stream.eol()) {
        const ch = stream.next()!
        if (escaped) { escaped = false; continue }
        if (ch === '\\') { escaped = true; continue }
        if (ch === quote) break
      }
      return 'string'
    }

    if (/[0-9\-]/.test(stream.peek() ?? '') && stream.match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/)) {
      return 'number'
    }

    if (stream.match(/^true\b/) || stream.match(/^false\b/)) {
      return 'atom'
    }

    if (stream.match(/^\d{4}-\d{2}-\d{2}/)) {
      stream.eatWhile(/[T :\d.Z]/)
      return 'number'
    }

    if (/[A-Za-z_]/.test(stream.peek() ?? '')) {
      stream.eatWhile(/[A-Za-z0-9_.\-]/)
      return state.inSection ? 'propertyName' : 'variableName'
    }

    stream.next()
    return null
  },
}

const tomlLanguage = StreamLanguage.define(tomlStreamParser)

// ── YAML StreamLanguage ──────────────────────────────

interface YamlStreamState {
  inKey: boolean
}

const YAML_KEYWORDS = new Set(['true', 'false', 'null', '~', 'yes', 'no', 'on', 'off'])

const yamlStreamParser: StreamParser<YamlStreamState> = {
  name: 'yaml',
  startState: () => ({ inKey: true }),
  copyState: state => ({ ...state }),
  languageData: {
    name: 'yaml',
    commentTokens: { line: '#' },
  },
  token(stream, state) {
    if (stream.eatSpace()) return null

    if (stream.peek() === '#') {
      stream.skipToEnd()
      return 'comment'
    }

    if (stream.sol() && (stream.match(/^---/) || stream.match(/^\.\./))) {
      stream.eatSpace()
      return 'operator'
    }

    if (stream.sol() && stream.peek() === '-') {
      stream.next()
      if (stream.eatSpace()) return 'operator'
    }

    if (stream.peek() === '"' || stream.peek() === '\'') {
      const quote = stream.next()!
      let escaped = false
      while (!stream.eol()) {
        const ch = stream.next()!
        if (escaped) { escaped = false; continue }
        if (ch === '\\') { escaped = true; continue }
        if (ch === quote) break
      }
      state.inKey = false
      return 'string'
    }

    if (stream.peek() === ':') {
      stream.next()
      if (stream.eatSpace()) {
        state.inKey = true
        return 'operator'
      }
      return null
    }

    if (/[0-9\-]/.test(stream.peek() ?? '') && stream.match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/)) {
      state.inKey = false
      return 'number'
    }

    if (/[A-Za-z_]/.test(stream.peek() ?? '')) {
      stream.eatWhile(/[A-Za-z0-9_.\-]/)
      const word = stream.current()
      if (YAML_KEYWORDS.has(word)) {
        state.inKey = false
        return 'atom'
      }
      if (state.inKey) return 'propertyName'
      state.inKey = false
      return 'string'
    }

    if (stream.peek() === '[' || stream.peek() === ']' || stream.peek() === '{' || stream.peek() === '}' || stream.peek() === ',') {
      stream.next()
      return 'operator'
    }

    stream.next()
    state.inKey = false
    return null
  },
}

const yamlLanguage = StreamLanguage.define(yamlStreamParser)

function readOcamlComment(stream: StringStream, state: OcamlStreamState): string {
  while (!stream.eol()) {
    if (stream.match('(*')) {
      state.commentDepth += 1
      continue
    }
    if (stream.match('*)')) {
      state.commentDepth -= 1
      if (state.commentDepth <= 0) {
        state.commentDepth = 0
        break
      }
      continue
    }
    stream.next()
  }
  return 'comment'
}

function readOcamlString(stream: StringStream, state: OcamlStreamState): string {
  let escaped = false
  while (!stream.eol()) {
    const ch = stream.next()
    if (escaped) {
      escaped = false
    } else if (ch === '\\') {
      escaped = true
    } else if (ch === state.stringQuote) {
      state.stringQuote = null
      break
    }
  }
  return 'string'
}

const LANGUAGE_MAP: Readonly<Record<string, LanguageEntry>> = {
  '.ts': { id: 'typescript', load: () => import('@codemirror/lang-javascript').then(m => m.javascript({ typescript: true })) },
  '.tsx': { id: 'typescript', load: () => import('@codemirror/lang-javascript').then(m => m.javascript({ typescript: true, jsx: true })) },
  '.js': { id: 'javascript', load: () => import('@codemirror/lang-javascript').then(m => m.javascript()) },
  '.jsx': { id: 'javascript', load: () => import('@codemirror/lang-javascript').then(m => m.javascript({ jsx: true })) },
  '.py': { id: 'python', load: () => import('@codemirror/lang-python').then(m => m.python()) },
  '.html': { id: 'html', load: () => import('@codemirror/lang-html').then(m => m.html()) },
  '.css': { id: 'css', load: () => import('@codemirror/lang-css').then(m => m.css()) },
  '.json': { id: 'json', load: () => import('@codemirror/lang-json').then(m => m.json()) },
  '.md': { id: 'markdown', load: () => import('@codemirror/lang-markdown').then(m => m.markdown()) },
  '.ocaml': { id: 'ocaml', load: () => Promise.resolve(ocamlLanguage) },
  '.ml': { id: 'ocaml', load: () => Promise.resolve(ocamlLanguage) },
  '.mli': { id: 'ocaml', load: () => Promise.resolve(ocamlLanguage) },
  '.rs': { id: 'rust', load: () => import('@codemirror/lang-rust').then(m => m.rust()) },
  '.go': { id: 'go', load: () => import('@codemirror/lang-go').then(m => m.go()) },
  '.toml': { id: 'toml', load: () => Promise.resolve(tomlLanguage) },
  '.yaml': { id: 'yaml', load: () => Promise.resolve(yamlLanguage) },
  '.yml': { id: 'yaml', load: () => Promise.resolve(yamlLanguage) },
}

export function languageIdForFilePath(filePath: string): string | null {
  const ext = filePath.slice(filePath.lastIndexOf('.'))
  return LANGUAGE_MAP[ext]?.id ?? null
}

export async function languageExt(filePath: string): Promise<Extension> {
  const ext = filePath.slice(filePath.lastIndexOf('.'))
  const loader = LANGUAGE_MAP[ext]?.load
  if (!loader) return []
  try {
    return await loader()
  } catch {
    return []
  }
}
