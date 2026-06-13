// @vitest-environment happy-dom
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { render } from 'preact'
import { html } from 'htm/preact'
import {
  BundleStalenessBanner,
  checkBundleStaleness,
  currentEntryBundleSrc,
  extractEntryBundleSrc,
  installBundleStalenessWatch,
  newerBundleAvailable,
  resetBundleStalenessState,
} from './bundle-staleness-banner'

const SERVED_HTML = (hash: string) => `<!DOCTYPE html>
<html lang="ko">
<head>
  <script type="module" crossorigin src="/dashboard/assets/index-${hash}.js"></script>
  <link rel="modulepreload" crossorigin href="/dashboard/assets/vendor-7p9DjONY.js">
</head>
<body><div id="app"></div></body>
</html>`

// No type="module": happy-dom would try to actually load the module
// and spam the run with fetch failures. The component queries on the
// src substring only, so the type attribute is irrelevant to the test.
const mountOwnEntryScript = (hash: string): HTMLScriptElement => {
  const script = document.createElement('script')
  script.setAttribute('src', `/dashboard/assets/index-${hash}.js`)
  document.head.appendChild(script)
  return script
}

const fetchReturning = (body: string, ok = true) =>
  vi.fn().mockResolvedValue({ ok, text: async () => body } as Response)

const flushUi = async () => {
  for (let i = 0; i < 4; i++) await Promise.resolve()
}

describe('extractEntryBundleSrc', () => {
  it('extracts the hashed entry path from served index.html', () => {
    expect(extractEntryBundleSrc(SERVED_HTML('fMmTbvTW')))
      .toBe('/dashboard/assets/index-fMmTbvTW.js')
  })

  it('ignores modulepreload chunks (href=, not src=)', () => {
    const noEntry = SERVED_HTML('x').replace(/<script[^>]*><\/script>/, '')
    expect(extractEntryBundleSrc(noEntry)).toBeNull()
  })

  it('returns null for dev-server HTML without a hashed entry', () => {
    expect(extractEntryBundleSrc('<script type="module" src="/src/main.tsx"></script>'))
      .toBeNull()
  })
})

describe('checkBundleStaleness', () => {
  let ownScript: HTMLScriptElement | null = null
  beforeEach(() => resetBundleStalenessState())
  afterEach(() => {
    ownScript?.remove()
    ownScript = null
    vi.restoreAllMocks()
    vi.unstubAllGlobals()
  })

  it('does not probe when the tab has no hashed entry (dev server)', async () => {
    const fetchSpy = fetchReturning(SERVED_HTML('AAAA'))
    expect(currentEntryBundleSrc()).toBeNull()
    await checkBundleStaleness(fetchSpy)
    expect(fetchSpy).not.toHaveBeenCalled()
    expect(newerBundleAvailable.value).toBe(false)
  })

  it('stays quiet when the served hash matches this tab', async () => {
    ownScript = mountOwnEntryScript('SAME')
    await checkBundleStaleness(fetchReturning(SERVED_HTML('SAME')))
    expect(newerBundleAvailable.value).toBe(false)
  })

  it('arms the banner when the server serves a different hash', async () => {
    ownScript = mountOwnEntryScript('OLD1')
    await checkBundleStaleness(fetchReturning(SERVED_HTML('NEW2')))
    expect(newerBundleAvailable.value).toBe(true)
  })

  it('treats a failed probe as no information (offline must not nag)', async () => {
    ownScript = mountOwnEntryScript('OLD1')
    await checkBundleStaleness(vi.fn().mockRejectedValue(new Error('offline')))
    expect(newerBundleAvailable.value).toBe(false)
  })

  it('treats a non-200 response as no information', async () => {
    ownScript = mountOwnEntryScript('OLD1')
    await checkBundleStaleness(fetchReturning('Service Unavailable', false))
    expect(newerBundleAvailable.value).toBe(false)
  })

  it('re-probes when the tab regains visibility', async () => {
    ownScript = mountOwnEntryScript('OLD1')
    vi.stubGlobal('fetch', fetchReturning(SERVED_HTML('NEW2')))
    const uninstall = installBundleStalenessWatch()
    document.dispatchEvent(new Event('visibilitychange'))
    await flushUi()
    expect(newerBundleAvailable.value).toBe(true)
    uninstall()
  })
})

describe('BundleStalenessBanner', () => {
  let container: HTMLElement
  beforeEach(() => {
    container = document.createElement('div')
    document.body.appendChild(container)
    resetBundleStalenessState()
  })
  afterEach(() => {
    document.body.removeChild(container)
  })

  it('renders nothing while the tab is current', () => {
    render(html`<${BundleStalenessBanner} />`, container)
    expect(container.querySelector('[data-bundle-staleness-banner]')).toBeNull()
  })

  it('shows reload + dismiss once a newer bundle is detected', async () => {
    newerBundleAvailable.value = true
    render(html`<${BundleStalenessBanner} />`, container)
    await flushUi()
    expect(container.querySelector('[data-bundle-staleness-banner]')).toBeTruthy()
  })

  it('reload button triggers the injected reload', async () => {
    newerBundleAvailable.value = true
    const reload = vi.fn()
    render(html`<${BundleStalenessBanner} reload=${reload} />`, container)
    await flushUi()
    const buttons = container.querySelectorAll('button')
    const reloadBtn = Array.from(buttons).find(b => b.textContent?.includes('새로고침'))!
    reloadBtn.click()
    expect(reload).toHaveBeenCalledTimes(1)
  })

  it('dismiss hides the banner without reloading', async () => {
    newerBundleAvailable.value = true
    render(html`<${BundleStalenessBanner} />`, container)
    await flushUi()
    const buttons = container.querySelectorAll('button')
    const dismissBtn = Array.from(buttons).find(b => b.textContent?.includes('나중에'))!
    dismissBtn.click()
    await flushUi()
    expect(container.querySelector('[data-bundle-staleness-banner]')).toBeNull()
  })
})
