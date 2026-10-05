import { signal } from '@preact/signals'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'
import { fetchLanePackageCatalog, fetchLanePackagePreview, type LanePackageCatalog, type LanePackagePreview } from '../api/lane-package-catalog'
import { initialBindingInput, packageDeclaration, parseBindingSchema, readBindingInput,
  type BindingInput, type BindingSchema } from './lane-binding-form'
import type { LaneDeclarationSession } from './lane-declaration-sessions'

export type PackageDraft = { preview: LanePackagePreview; schema: BindingSchema; input: BindingInput;
  id: string; runId: string; dirty: boolean; previewAuthority: ExecutionWorkspaceAuthority | null }
type State = { visible: boolean; catalog: LanePackageCatalog | null; folder: string | null; folderInput: string; manifestInput: string;
  drafts: Map<string, PackageDraft>; selected: string | null;
  phase: 'idle' | 'catalog' | 'preview'; error: string | null }
const sessions = new Map<string, LanePackageInstallationSession>()
const message = (error: unknown) => error instanceof Error ? error.message : String(error)
const warnUnload = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
let guarding = false
function syncGuard() {
  const dirty = [...sessions.values()].some(owner => [...owner.state.peek().drafts.values()].some(draft => draft.dirty))
  if (typeof window === 'undefined' || guarding === dirty) return
  guarding = dirty
  if (dirty) window.addEventListener('beforeunload', warnUnload)
  else window.removeEventListener('beforeunload', warnUnload)
}
export class LanePackageInstallationSession {
  readonly state = signal<State>({ visible: false, catalog: null, folder: null, folderInput: '', manifestInput: '', drafts: new Map(), selected: null, phase: 'idle', error: null })
  private authority: ExecutionWorkspaceAuthority | null = null
  private request: AbortController | null = null
  private generation = 0
  // The manifest path each typed input named on its last successful preview.
  // The server resolves an alias such as `addons/foo/lane.toml` to an absolute
  // manifest_path, and drafts are keyed by that canonical path, so a recheck
  // through the alias must invalidate the canonical draft too.
  private readonly resolved = new Map<string, string>()
  constructor(readonly workspaceRoot: string) {}
  admits(authority: ExecutionWorkspaceAuthority) { return executionWorkspaceAuthority.peek() === authority && authority.workspaceRoot === this.workspaceRoot }
  attach(authority: ExecutionWorkspaceAuthority) {
    if (!this.admits(authority) || this.authority === authority) return
    this.authority = authority; this.request?.abort(); this.generation++
    this.resolved.clear()
    const state = this.state.peek()
    this.state.value = { ...state, catalog: null, phase: 'idle', error: null,
      drafts: new Map([...state.drafts].map(([key, draft]) => [key, { ...draft, previewAuthority: null }])) }
  }
  open(authority: ExecutionWorkspaceAuthority) {
    if (!this.admits(authority)) return
    this.state.value = { ...this.state.peek(), visible: true }
    if (this.state.peek().catalog === null) void this.browse(this.state.peek().folder, authority)
  }
  close() {
    this.request?.abort(); this.generation++
    this.state.value = { ...this.state.peek(), visible: false, phase: 'idle', error: null }
  }
  private async read<T>(phase: 'catalog' | 'preview', authority: ExecutionWorkspaceAuthority,
    fetch: (signal: AbortSignal) => Promise<T>, apply: (value: T, state: State) => State) {
    if (!this.admits(authority)) return
    this.request?.abort(); const request = new AbortController(); this.request = request
    const generation = ++this.generation
    this.state.value = { ...this.state.peek(), phase, error: null }
    const current = () => this.admits(authority) && generation === this.generation && !request.signal.aborted
    try {
      const value = await fetch(request.signal)
      if (current()) this.state.value = { ...apply(value, this.state.peek()), phase: 'idle' }
    } catch (error) {
      if (current()) this.state.value = { ...this.state.peek(), phase: 'idle', error: message(error) }
    }
  }
  browse(directory: string | null, authority: ExecutionWorkspaceAuthority) {
    return this.read('catalog', authority, signal => fetchLanePackageCatalog(directory, signal),
      (catalog, state) => ({ ...state, catalog, folder: catalog.directory }))
  }
  editPath(field: 'folderInput' | 'manifestInput', text: string, authority: ExecutionWorkspaceAuthority) {
    if (this.admits(authority)) this.state.value = { ...this.state.peek(), [field]: text }
  }
  preview(path: string, authority: ExecutionWorkspaceAuthority) {
    if (!this.admits(authority)) return Promise.resolve()
    const state = this.state.peek()
    const canonical = this.resolved.get(path) ?? path
    const rechecks = (draft: PackageDraft | undefined) =>
      draft !== undefined && (draft.preview.manifest_path === path || draft.preview.manifest_path === canonical)
    this.state.value = { ...state,
      selected: state.selected !== null && rechecks(state.drafts.get(state.selected)) ? state.selected : null,
      drafts: new Map([...state.drafts].map(([key, draft]) => [key,
        rechecks(draft) ? { ...draft, previewAuthority: null } : draft])) }
    return this.read('preview', authority, signal => fetchLanePackagePreview(path, signal), (preview, state) => {
      if (preview.package.binding_schema === null) throw new Error('This package has no binding schema. Use New TOML for an advanced declaration.')
      const schema = parseBindingSchema(preview.package.binding_schema)
      if (schema.type !== 'object') throw new Error('Package binding schema must describe an object.')
      this.resolved.set(path, preview.manifest_path)
      const key = JSON.stringify([preview.manifest_path, preview.package.binding_schema])
      const prior = state.drafts.get(key)
      const draft: PackageDraft = prior ? { ...prior, preview, previewAuthority: authority }
        : { preview, schema, input: initialBindingInput(schema), id: '', runId: '', dirty: false, previewAuthority: authority }
      const drafts = new Map([...state.drafts].map(([otherKey, other]) =>
        [otherKey, otherKey !== key && other.preview.manifest_path === preview.manifest_path ? { ...other, previewAuthority: null } : other]))
      return { ...state, drafts: drafts.set(key, draft), selected: key }
    })
  }
  select(key: string, authority: ExecutionWorkspaceAuthority) {
    if (this.admits(authority) && this.state.peek().drafts.has(key)) this.state.value = { ...this.state.peek(), selected: key, error: null }
  }
  update(key: string, change: Partial<Pick<PackageDraft, 'id' | 'runId' | 'input'>>, authority: ExecutionWorkspaceAuthority) {
    if (!this.admits(authority)) return
    const state = this.state.peek(), draft = state.drafts.get(key)
    if (!draft) return
    this.state.value = { ...state, drafts: new Map(state.drafts).set(key, { ...draft, ...change, dirty: true }), error: null }
    syncGuard()
  }
  prepare(key: string, documents: LaneDeclarationSession, authority: ExecutionWorkspaceAuthority) {
    if (!this.admits(authority)) return
    const state = this.state.peek(), draft = state.drafts.get(key)
    if (!draft || state.phase !== 'idle') return
    try {
      if (draft.previewAuthority !== authority) throw new Error('Recheck this package in the current workspace before preparing a draft. Your inputs are retained.')
      const binding = readBindingInput(draft.schema, draft.input)
      const text = packageDeclaration(draft.id, draft.runId, draft.preview.manifest_path, binding)
      documents.prepare(`${draft.id}.toml`, text, authority)
      this.state.value = { ...state, visible: false, error: null, drafts: new Map(state.drafts).set(key, { ...draft, dirty: false }) }
      syncGuard()
    } catch (error) { this.state.value = { ...this.state.peek(), error: message(error) } }
  }
}
export function lanePackageInstallationFor(authority: ExecutionWorkspaceAuthority, directory: string) {
  const key = JSON.stringify([authority.workspaceRoot, directory])
  let owner = sessions.get(key)
  if (!owner) { owner = new LanePackageInstallationSession(authority.workspaceRoot); sessions.set(key, owner) }
  owner.attach(authority)
  return owner
}
export function resetLanePackageInstallationsForTesting() {
  for (const owner of sessions.values()) owner.close()
  sessions.clear(); syncGuard()
}
