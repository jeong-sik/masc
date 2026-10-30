import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { runInNewContext } from 'node:vm'
import { vi } from 'vitest'

/** Execute the literal script served by the production OCaml route. The
 * HTTP renderer/CSP and browser process are outside this component fixture. */
export function callbackPage(url: string, opener: { postMessage: (data: unknown, origin: string) => void } | null) {
  const source = readFileSync(resolve(process.cwd(), '../lib/server/server_routes_http_routes_lane_addons.ml'), 'utf8')
  const marker = '  let script = {|'
  const start = source.indexOf(marker)
  const end = source.indexOf('|} in', start)
  if (start < 0 || end < 0) throw new Error('Production callback script unavailable')
  const script = source.slice(start + marker.length, end)
  let receive!: (event: { data: unknown; source: unknown; origin: string }) => void
  let retry!: () => void
  const status = { textContent: '' }
  const page = { location: { href: url, origin: new URL(url).origin, pathname: new URL(url).pathname },
    opener, history: { replaceState: vi.fn() }, close: vi.fn(),
    addEventListener: (_: string, listener: typeof receive) => { receive = listener } }
  runInNewContext(script, { window: page, URL, document: { getElementById: (id: string) => id === 'status'
    ? status : { addEventListener: (_: string, listener: () => void) => { retry = listener } } } })
  return { page, status, retry: () => retry(),
    receive: (data: unknown, source: unknown = opener, origin = page.location.origin) => receive({ data, source, origin }) }
}
