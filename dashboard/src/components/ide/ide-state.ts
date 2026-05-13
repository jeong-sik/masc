/**
 * IDE shared signals — minimal state module.
 *
 * Extracted from `ide-shell.ts` to break a circular dependency:
 * `ide-shell` already imports `InspectorKeeperBDI` (and other heavy IDE
 * components), so importing `activeIdeFile` from `ide-shell` inside those
 * children re-enters the shell module at evaluation time and pulls
 * `router` (window-touching at module-eval) into every importer.
 *
 * Keep this module side-effect free: only signals/types live here.
 */

import { signal } from '@preact/signals'
import type { TabId } from '../../types'

export const activeIdeFile = signal<string>('package.json')

export interface IdeContextFocusRouteLink {
  readonly id: string
  readonly label: string
  readonly tab: TabId
  readonly params: Record<string, string>
  readonly evidence: string
}

export interface IdeContextFocus {
  readonly file_path: string
  readonly line?: number
  readonly surface: string
  readonly label: string
  readonly source_id: string
  readonly keeper_id?: string
  readonly route_links?: ReadonlyArray<IdeContextFocusRouteLink>
  readonly activated_at_ms: number
}

export const ideContextFocus = signal<IdeContextFocus | null>(null)

export function focusIdeContextAnchor(
  anchor: Omit<IdeContextFocus, 'activated_at_ms'>,
): void {
  const filePath = normalizeIdeContextFilePath(anchor.file_path)
  if (filePath === null) return
  const line = normalizeIdeContextLine(anchor.line)
  activeIdeFile.value = filePath
  ideContextFocus.value = {
    ...anchor,
    file_path: filePath,
    line,
    activated_at_ms: Date.now(),
  }
}

function normalizeIdeContextLine(value: number | undefined): number | undefined {
  return Number.isSafeInteger(value) && value !== undefined && value >= 1
    ? value
    : undefined
}

function normalizeIdeContextFilePath(value: string): string | null {
  const filePath = value.trim().replace(/\\/g, '/')
  if (filePath === '' || filePath.startsWith('/') || /^[A-Za-z]:\//.test(filePath)) {
    return null
  }
  const segments = filePath.split('/')
  if (segments.some(segment => segment === '' || segment === '.' || segment === '..')) {
    return null
  }
  return filePath
}
