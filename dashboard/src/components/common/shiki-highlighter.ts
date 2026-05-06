import DOMPurify from 'dompurify'

interface DashboardHighlighter {
  getLoadedLanguages(): string[]
  loadLanguage(...langs: unknown[]): Promise<void>
  codeToHtml(code: string, options: { lang: string; theme: string }): string
}

type ShikiLanguageModule = { default: unknown | unknown[] }
type ShikiLanguageLoader = () => Promise<ShikiLanguageModule>

const SHIKI_THEME = 'vitesse-dark'
const SHIKI_LANG_ALIASES: Record<string, string> = {
  js: 'javascript',
  jsx: 'javascript',
  ts: 'typescript',
  tsx: 'typescript',
  py: 'python',
  sh: 'bash',
  shell: 'bash',
  zsh: 'bash',
  yml: 'yaml',
  md: 'markdown',
  ml: 'ocaml',
  mli: 'ocaml',
}
const SHIKI_LANG_LOADERS: Record<string, ShikiLanguageLoader> = {
  bash: () => import('shiki/langs/bash.mjs'),
  css: () => import('shiki/langs/css.mjs'),
  diff: () => import('shiki/langs/diff.mjs'),
  go: () => import('shiki/langs/go.mjs'),
  html: () => import('shiki/langs/html.mjs'),
  javascript: () => import('shiki/langs/javascript.mjs'),
  json: () => import('shiki/langs/json.mjs'),
  markdown: () => import('shiki/langs/markdown.mjs'),
  ocaml: () => import('shiki/langs/ocaml.mjs'),
  python: () => import('shiki/langs/python.mjs'),
  rust: () => import('shiki/langs/rust.mjs'),
  sql: () => import('shiki/langs/sql.mjs'),
  typescript: () => import('shiki/langs/typescript.mjs'),
  yaml: () => import('shiki/langs/yaml.mjs'),
}

const SHIKI_PURIFY_CONFIG = {
  ALLOWED_TAGS: ['pre', 'code', 'span'],
  ALLOWED_ATTR: ['class', 'style'],
}

let shikiPromise: Promise<DashboardHighlighter> | null = null
let loadedShikiLanguages = new Set<string>()

export async function highlightCodeHtml(code: string, lang: string): Promise<string> {
  const highlighter = await getShiki()
  const loadedLang = await ensureShikiLanguage(highlighter, lang).catch(() => 'text')
  const rawHtml = highlighter.codeToHtml(code, { lang: loadedLang, theme: SHIKI_THEME })
  return sanitizeShikiHtml(rawHtml)
}

export async function highlightCodeLines(
  code: string,
  lang: string,
  expectedLineCount = splitCodeLines(code).length,
): Promise<ReadonlyArray<string>> {
  if (expectedLineCount === 0) return []
  const safeHtml = await highlightCodeHtml(code, lang)
  const div = document.createElement('div')
  div.innerHTML = safeHtml
  const codeEl = div.querySelector('code')
  if (!codeEl) return plainEscapedLines(code, expectedLineCount)

  let lineHtml = Array.from(codeEl.children)
    .filter((child): child is HTMLElement => child instanceof HTMLElement && child.classList.contains('line'))
    .map(line => line.innerHTML)
  if (lineHtml.length === expectedLineCount + 1 && lineHtml[lineHtml.length - 1] === '') {
    lineHtml = lineHtml.slice(0, expectedLineCount)
  }
  if (lineHtml.length !== expectedLineCount) {
    return plainEscapedLines(code, expectedLineCount)
  }
  return lineHtml
}

function getShiki(): Promise<DashboardHighlighter> {
  if (!shikiPromise) {
    shikiPromise = Promise.all([
      import('shiki/core'),
      import('shiki/engine/javascript'),
      import('shiki/themes/vitesse-dark.mjs'),
    ]).then(async ([shiki, engine, theme]) => {
      loadedShikiLanguages = new Set()
      return shiki.createHighlighterCore({
        themes: [theme.default],
        langs: [],
        engine: engine.createJavaScriptRegexEngine(),
      })
    }).catch((err) => {
      shikiPromise = null
      loadedShikiLanguages = new Set()
      throw err
    })
  }
  return shikiPromise
}

function normalizeShikiLang(lang: string): string {
  const normalized = lang.trim().toLowerCase()
  return SHIKI_LANG_ALIASES[normalized] ?? normalized
}

async function ensureShikiLanguage(highlighter: DashboardHighlighter, lang: string): Promise<string> {
  const normalized = normalizeShikiLang(lang)
  if (normalized === 'text') return 'text'
  const loader = SHIKI_LANG_LOADERS[normalized]
  if (!loader) return 'text'
  if (loadedShikiLanguages.has(normalized) || highlighter.getLoadedLanguages().includes(normalized)) {
    return normalized
  }
  const module = await loader()
  const registrations = Array.isArray(module.default) ? module.default : [module.default]
  await highlighter.loadLanguage(...registrations)
  loadedShikiLanguages.add(normalized)
  return normalized
}

function sanitizeShikiHtml(raw: string): string {
  return DOMPurify.sanitize(raw, SHIKI_PURIFY_CONFIG)
}

function plainEscapedLines(code: string, expectedLineCount: number): ReadonlyArray<string> {
  const lines = splitCodeLines(code)
    .slice(0, expectedLineCount)
    .map(escapeHtml)
  while (lines.length < expectedLineCount) lines.push('')
  return lines
}

function splitCodeLines(code: string): ReadonlyArray<string> {
  const normalized = code.replace(/\r\n?/g, '\n')
  if (normalized === '') return []
  const body = normalized.endsWith('\n') ? normalized.slice(0, -1) : normalized
  return body.split('\n')
}

function escapeHtml(value: string): string {
  const span = document.createElement('span')
  span.textContent = value
  return span.innerHTML
}
