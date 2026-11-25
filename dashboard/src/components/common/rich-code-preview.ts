import bravuraUrl from '@coderline/alphatab/font/Bravura.woff2?url'

type RichCodeKind = 'mermaid' | 'pele' | 'alphatex'

const labels: Record<RichCodeKind, string> = {
  mermaid: 'Mermaid 다이어그램',
  pele: 'Pele 다이어그램',
  alphatex: 'Guitar Tab',
}

export function richCodeKind(tag: string): RichCodeKind | undefined {
  switch (tag.toLowerCase()) {
    case 'mermaid': return 'mermaid'
    case 'pele': return 'pele'
    case 'alphatex':
    case 'atex': return 'alphatex'
    default: return undefined
  }
}

async function renderDiagram(host: HTMLElement, source: string, label: string, signal: AbortSignal) {
  const { renderAsync } = await import('pele/lazy')
  signal.throwIfAborted()
  const { svg } = await renderAsync(source, {
    maxWidth: host.clientWidth || undefined,
    links: false,
    images: false,
  })
  signal.throwIfAborted()

  const doc = new DOMParser().parseFromString(svg, 'image/svg+xml')
  if (doc.documentElement.localName !== 'svg') throw new Error('Invalid diagram SVG')
  const palette = getComputedStyle(host)
  const colors = [
    ['fg', '--fg-1'],
    ['bg', '--bg-2'],
    ['line', '--fg-2'],
    ['muted', '--fg-3'],
    ['border', '--line-2'],
    ['surface', '--bg-3'],
    ['surface-alt', '--bg-1'],
  ] as const
  for (const [name, token] of colors) {
    const value = palette.getPropertyValue(token).trim()
    if (value) doc.documentElement.style.setProperty(`--pele-${name}`, value)
  }

  // Load SVG as an image so Mermaid author content stays outside the document DOM.
  const image = host.ownerDocument.createElement('img')
  image.alt = label
  image.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(new XMLSerializer().serializeToString(doc))}`
  await image.decode()
  signal.throwIfAborted()
  host.append(image)
}

async function renderScore(host: HTMLElement, source: string, signal: AbortSignal) {
  const { AlphaTabApi, FontFileFormat, StaveProfile } = await import('@coderline/alphatab')
  signal.throwIfAborted()
  const api = new AlphaTabApi(host, {
    core: {
      useWorkers: false,
      smuflFontSources: new Map([[FontFileFormat.Woff2, bravuraUrl]]),
    },
    display: { staveProfile: StaveProfile.Tab },
  })
  signal.addEventListener('abort', () => api.destroy(), { once: true })

  await new Promise<void>((resolve, reject) => {
    const aborted = () => reject(signal.reason)
    signal.addEventListener('abort', aborted, { once: true })
    api.renderFinished.on(() => {
      signal.removeEventListener('abort', aborted)
      resolve()
    })
    api.error.on(error => {
      signal.removeEventListener('abort', aborted)
      reject(error)
    })
    api.tex(source, 'all')
  })
}

export function enhanceRichCode(root: HTMLElement): () => void {
  const controllers: AbortController[] = []
  const cleanups: Array<() => void> = []
  const observer = typeof IntersectionObserver === 'undefined'
    ? undefined
    : new IntersectionObserver(entries => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue
          observer?.unobserve(entry.target)
          pending.get(entry.target)?.()
          pending.delete(entry.target)
        }
      }, { rootMargin: '200px' })
  const pending = new Map<Element, () => void>()

  for (const code of root.querySelectorAll<HTMLElement>('pre > code')) {
    const tag = [...code.classList].find(name => name.startsWith('language-'))?.slice('language-'.length)
    const kind = tag && richCodeKind(tag)
    const pre = code.parentElement
    if (!kind || !pre || !code.textContent?.trim()) continue

    const source = code.textContent
    const preview = async () => {
      const controller = new AbortController()
      const { signal } = controller
      controllers.push(controller)
      const host = root.ownerDocument.createElement('div')
      host.className = kind === 'alphatex' ? 'rich-code-preview rich-code-score' : 'rich-code-preview'
      host.setAttribute('role', 'img')
      host.setAttribute('aria-label', labels[kind])
      pre.before(host)
      cleanups.push(() => host.remove())

      try {
        if (kind === 'alphatex') await renderScore(host, source, signal)
        else await renderDiagram(host, source, labels[kind], signal)
        if (signal.aborted || !pre.parentNode) return
        const details = root.ownerDocument.createElement('details')
        const summary = root.ownerDocument.createElement('summary')
        summary.textContent = `${labels[kind]} 원문`
        pre.before(details)
        details.append(summary, pre)
        cleanups.push(() => {
          if (details.parentNode) details.replaceWith(pre)
        })
      } catch {
        controller.abort()
        host.remove()
      }
    }
    if (observer) {
      pending.set(pre, () => { void preview() })
      observer.observe(pre)
    } else {
      void preview()
    }
  }

  return () => {
    observer?.disconnect()
    pending.clear()
    for (const controller of controllers) controller.abort()
    for (const cleanup of cleanups) cleanup()
  }
}
