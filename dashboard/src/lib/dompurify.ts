import createDOMPurify, { type Config, type DOMPurify } from 'dompurify'

let purifier: DOMPurify | null = null
let purifierDocument: Document | null = null
let purifierPassedSmokeTest = false

function currentWindow(): Window & typeof globalThis {
  if (typeof window === 'undefined' || !window.document) {
    throw new Error('DOMPurify requires an active window.document')
  }
  return window as Window & typeof globalThis
}

function getPurifier(): DOMPurify {
  const activeWindow = currentWindow()
  if (!purifier || purifierDocument !== activeWindow.document) {
    purifier = createDOMPurify(activeWindow)
    purifierDocument = activeWindow.document
    purifierPassedSmokeTest = purifierPassesSmokeTest(purifier)
  }
  return purifier
}

export type SanitizeConfig = Config

export function sanitizeHtml(raw: string, config?: Config): string {
  const activePurifier = getPurifier()
  if (!purifierPassedSmokeTest) return fallbackSanitizeHtml(raw)
  return activePurifier.sanitize(raw, config)
}

function purifierPassesSmokeTest(activePurifier: DOMPurify): boolean {
  if (!activePurifier.isSupported) return false
  const scriptOutput = activePurifier.sanitize('<p>ok<script>alert(1)</script></p>')
  const linkOutput = activePurifier.sanitize('<a href="javascript:alert(1)">x</a>', {
    ALLOWED_TAGS: ['a'],
    ALLOWED_ATTR: ['href'],
  })
  const preOutput = activePurifier.sanitize('<pre><code>x</code></pre>', {
    ALLOWED_TAGS: ['pre', 'code'],
    ALLOWED_ATTR: [],
  })
  return !containsUnsafeMarkup(scriptOutput)
    && !containsUnsafeMarkup(linkOutput)
    && preOutput.includes('<pre')
}

function containsUnsafeMarkup(value: string): boolean {
  const normalized = value.toLowerCase()
  return normalized.includes('<script')
    || normalized.includes('javascript:')
    || normalized.includes('vbscript:')
}

function fallbackSanitizeHtml(raw: string): string {
  const text = currentWindow().document.createElement('span')
  text.textContent = raw
  return text.innerHTML
}
