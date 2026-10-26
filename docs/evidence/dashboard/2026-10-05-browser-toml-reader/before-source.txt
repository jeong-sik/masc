import { getStaticTOMLValue, parseTOML } from 'toml-eslint-parser'
import type { LaneInventoryRow } from '../api/lane-inventory'
import { isRecord } from './type-guards'
import { deleteRuntimeTomlKey, setRuntimeTomlKey } from './runtime-toml-config'

export type BrowserActivityLane = Extract<LaneInventoryRow['selection'], { kind: 'browser' }>['lane']

function table(value: unknown, path: string): Record<string, unknown> {
  if (value === undefined) return {}
  if (!isRecord(value) || ![null, Object.prototype].includes(Object.getPrototypeOf(value)))
    throw new Error(`${path}는 TOML table이어야 합니다.`)
  return value
}

function browserTable(source: string) {
  const root = table(getStaticTOMLValue(parseTOML(source, { tomlVersion: '1.0' })), '설정')
  const browser = table(root.browser, 'browser')
  if (Object.hasOwn(browser, 'automation')
    && (Object.hasOwn(browser, 'geckodriver') || Object.hasOwn(browser, 'binary')))
    throw new Error('automation 경로는 [browser]와 [browser.automation] 중 한 곳에만 설정해야 합니다.')
  return browser
}

/** Read the selected activity flag. Full backend/path validation belongs to
 * the server preview; opening this editor neither installs nor starts it. */
export function readBrowserActivity(source: string, lane: BrowserActivityLane): { enabled: boolean } {
  const selected = table(browserTable(source)[lane], `browser.${lane}`)
  const enabled = Object.hasOwn(selected, 'enabled') ? selected.enabled : true
  if (typeof enabled !== 'boolean') throw new Error('enabled는 true 또는 false여야 합니다.')
  return { enabled }
}

/** Edit the selected flag using parsed TOML ranges. An automation edit moves
 * accepted flat paths into its table so the server never receives both forms.
 * Unchanged source and inline comments on an existing enabled value survive;
 * comments attached to moved path assignments are not retained by the editor. */
export function writeBrowserActivity(source: string, lane: BrowserActivityLane, enabled: boolean): string {
  readBrowserActivity(source, lane)
  let next = source
  if (lane === 'automation') {
    const browser = browserTable(source)
    for (const key of ['geckodriver', 'binary']) {
      if (!Object.hasOwn(browser, key)) continue
      const value = browser[key]
      if (typeof value !== 'string') throw new Error(`${key}는 경로 문자열이어야 합니다.`)
      next = deleteRuntimeTomlKey(next, 'browser', key)
      next = setRuntimeTomlKey(next, 'browser.automation', key, value)
    }
  }
  next = setRuntimeTomlKey(next, `browser.${lane}`, 'enabled', enabled)
  readBrowserActivity(next, lane)
  return next
}
