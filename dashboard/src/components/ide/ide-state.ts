/**
 * IDE shared signals — minimal state module.
 *
 * Extracted from `ide-shell.ts` to break a circular dependency:
 * `ide-shell` imports heavy IDE components, so importing `activeIdeFile`
 * from `ide-shell` inside those children re-enters the shell module at
 * evaluation time and pulls `router` (window-touching at module-eval) into
 * every importer.
 *
 * Keep this module side-effect free: only signals/types live here.
 */

import { computed, signal } from '@preact/signals'
import type { TabId } from '../../types'
import { isPositiveSafeInteger } from '../common/normalize'

export type IdeFileFocusOrigin = 'operator' | 'route' | 'observed_change'
export type ExplicitIdeFileFocusOrigin = Exclude<IdeFileFocusOrigin, 'observed_change'>
export type ExplicitIdeFileFocusAvailability =
  | 'pending'
  | 'available'
  | 'not_found'
  | 'unavailable'
export type ObservedIdeFileFocusAvailability = 'available' | 'unavailable'
export type IdeFileFocusAvailability =
  | ExplicitIdeFileFocusAvailability
  | ObservedIdeFileFocusAvailability

export type IdeWorkspaceIdentity =
  | { readonly kind: 'project' }
  | { readonly kind: 'repository'; readonly repoId: string }
  | { readonly kind: 'keeper'; readonly keeper: string }

interface IdeFileFocusBase {
  readonly path: string
  readonly workspace_identity: IdeWorkspaceIdentity
}

export type IdeFileFocus = IdeFileFocusBase & (
  | {
      readonly origin: ExplicitIdeFileFocusOrigin
      readonly availability: ExplicitIdeFileFocusAvailability
    }
  | {
      readonly origin: 'observed_change'
      readonly availability: ObservedIdeFileFocusAvailability
    }
)

type IdeFileFocusRequestBase = {
  readonly path: string
  readonly workspace_identity?: IdeWorkspaceIdentity
}

export type IdeFileFocusRequest = IdeFileFocusRequestBase & (
  | {
      readonly origin: ExplicitIdeFileFocusOrigin
      readonly availability: ExplicitIdeFileFocusAvailability
    }
  | {
      readonly origin: 'observed_change'
      readonly availability: ObservedIdeFileFocusAvailability
    }
)

const activeIdeWorkspaceIdentitySignal = signal<IdeWorkspaceIdentity>({ kind: 'project' })
const activeIdeFocusSignal = signal<IdeFileFocus | null>(null)

/** Read-only projections. State transitions go through the typed functions below. */
export const activeIdeWorkspaceIdentity = computed(() => activeIdeWorkspaceIdentitySignal.value)
export const activeIdeFocus = computed(() => activeIdeFocusSignal.value)

/** Compatibility-free path projection for render consumers; it is not writable. */
export const activeIdeFile = computed(() => activeIdeFocus.value?.path ?? null)

export function synchronizeIdeWorkspaceIdentity(identity: IdeWorkspaceIdentity): void {
  if (!sameIdeWorkspaceIdentity(activeIdeWorkspaceIdentitySignal.peek(), identity)) {
    activeIdeWorkspaceIdentitySignal.value = identity
  }
}

export function ideWorkspaceIdentityForSelection(
  repoId: string | null | undefined,
  keeper: string | null | undefined,
): IdeWorkspaceIdentity {
  const normalizedRepoId = repoId?.trim()
  if (normalizedRepoId) return { kind: 'repository', repoId: normalizedRepoId }
  const normalizedKeeper = keeper?.trim()
  if (normalizedKeeper) return { kind: 'keeper', keeper: normalizedKeeper }
  return { kind: 'project' }
}

export function sameIdeWorkspaceIdentity(
  left: IdeWorkspaceIdentity,
  right: IdeWorkspaceIdentity,
): boolean {
  if (left.kind !== right.kind) return false
  switch (left.kind) {
    case 'project':
      return true
    case 'repository':
      return right.kind === 'repository' && left.repoId === right.repoId
    case 'keeper':
      return right.kind === 'keeper' && left.keeper === right.keeper
  }
}

export function focusIdeFile(
  request: IdeFileFocusRequest,
): boolean {
  const path = normalizeIdeContextFilePath(request.path)
  if (path === null) return false
  const workspaceIdentity = request.workspace_identity ?? activeIdeWorkspaceIdentitySignal.value
  activeIdeFocusSignal.value = {
    ...request,
    path,
    workspace_identity: workspaceIdentity,
  }
  return true
}

export function clearIdeFileFocus(): void {
  activeIdeFocusSignal.value = null
}

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
  origin: ExplicitIdeFileFocusOrigin,
): void {
  const filePath = normalizeIdeContextFilePath(anchor.file_path)
  if (filePath === null) return
  const line = normalizeIdeContextLine(anchor.line)
  focusIdeFile({
    path: filePath,
    origin,
    availability: 'pending',
  })
  ideContextFocus.value = {
    ...anchor,
    file_path: filePath,
    line,
    activated_at_ms: Date.now(),
  }
}

export function normalizeIdeContextLine(value: number | undefined): number | undefined {
  return isPositiveSafeInteger(value) ? value : undefined
}

export function normalizeIdeContextFilePath(value: string): string | null {
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
