import assert from 'node:assert/strict'
import { createServer } from 'node:http'
import { once } from 'node:events'
import vm from 'node:vm'
import { Window } from 'happy-dom'
import type { SiteOutput } from '../src/site.ts'

// Trusted fixture only. This is a controlled DOM/ESM consumer, not a browser or
// a production site server. Every module request goes to our own HTTP server.
export async function runTrustedSite(site: SiteOutput) {
  const requested: string[] = [], files = new Map(site.files.map(file => [file.path, Buffer.from(file.content_base64, 'base64')]))
  const server = createServer((request, response) => {
    const path = decodeURIComponent(new URL(request.url!, 'http://fixture.invalid').pathname.slice(1)) || site.entry_html
    requested.push(path)
    const content = files.get(path)
    if (!content) { response.writeHead(404); response.end(); return }
    const type = path.endsWith('.js') ? 'text/javascript' : path.endsWith('.css') ? 'text/css' : path.endsWith('.html') ? 'text/html' : path.endsWith('.json') ? 'application/json' : 'application/octet-stream'
    response.writeHead(200, { 'content-type': type }); response.end(content)
  })
  server.listen(0, '127.0.0.1'); await once(server, 'listening')
  const address = server.address(); assert.ok(address && typeof address === 'object')
  const origin = `http://127.0.0.1:${address.port}`
  const window = new Window({ url: origin + '/' + site.entry_html, settings: { disableCSSFileLoading: true, disableJavaScriptFileLoading: true } })
  const fetchLocal = (path: string, init?: RequestInit) => {
    const url = new URL(path, origin)
    assert.equal(url.origin, origin, 'unexpected external request in trusted fixture')
    return fetch(url, init)
  }
  window.fetch = fetchLocal as unknown as Window['fetch']
  try {
    // Also verify all non-code output bytes through the actual HTTP path.
    for (const file of site.files) {
      const response = await fetchLocal('/' + file.path.split('/').map(encodeURIComponent).join('/'))
      assert.equal(response.status, 200)
      assert.deepEqual(Buffer.from(await response.arrayBuffer()), files.get(file.path))
    }
    const html = await (await fetchLocal('/' + site.entry_html)).text()
    window.document.write(html)
    const context = vm.createContext(window), modules = new Map<string, Promise<vm.SourceTextModule>>()
    const load = (url: string): Promise<vm.SourceTextModule> => {
      if (!modules.has(url)) modules.set(url, (async () => {
        const response = await fetchLocal(url); assert.equal(response.status, 200)
        return new vm.SourceTextModule(await response.text(), { context, identifier: url,
          initializeImportMeta(meta) { meta.url = url },
          importModuleDynamically: async (specifier, parent) => {
            const child = await load(new URL(specifier, parent.identifier).href)
            if (child.status === 'unlinked') await child.link(link)
            if (child.status === 'linked') await child.evaluate()
            return child
          },
        })
      })())
      return modules.get(url)!
    }
    const link = (specifier: string, parent: vm.Module) => load(new URL(specifier, parent.identifier).href)
    for (const script of window.document.querySelectorAll('script[type=module]')) {
      assert.ok(script.getAttribute('src'))
      const module = await load(new URL(script.getAttribute('src')!, origin).href)
      if (module.status === 'unlinked') await module.link(link)
      if (module.status === 'linked') await module.evaluate()
    }
    const button = window.document.getElementById('counter')!
    assert.equal(button.textContent, '함께 만든 앱 0 설정 적용됨 😀')
    const changed = new Promise<void>(resolve => {
      const observer = new window.MutationObserver(() => {
        if (button.textContent === '함께 만든 앱 1 분할 모듈 실행 😀') { observer.disconnect(); resolve() }
      })
      observer.observe(button, { subtree: true, childList: true, characterData: true })
    })
    button.dispatchEvent(new window.MouseEvent('click', { bubbles: true }))
    await changed
    assert.equal(button.className, 'counter changed')
    assert.ok(modules.size > 1, 'dynamic split module was actually loaded')
    return { before: '함께 만든 앱 0 설정 적용됨 😀', after: button.textContent, moduleURLs: [...modules.keys()], requested, browserVerified: false }
  } finally {
    await window.happyDOM.close(); server.closeAllConnections(); await new Promise<void>(done => server.close(() => done()))
  }
}
