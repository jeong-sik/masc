import { describe, expect, it } from 'vitest'
import { buildIdeInterjectSurfaceContext } from './ide-interject-surface-context'
import type { IdeFileFocus } from './ide-state'

function focusOn(path: string, workspace_identity: IdeFileFocus['workspace_identity'] = { kind: 'project' }): IdeFileFocus {
  return {
    path,
    workspace_identity,
    origin: 'operator',
    availability: 'available',
  }
}

describe('buildIdeInterjectSurfaceContext', () => {

  // RFC-0378 §5.3/§5.3b — the codebase slug is the anchor contract.
  it('carries the codebase slug for a repository identity', () => {
    const context = buildIdeInterjectSurfaceContext({
      focus: focusOn('lib/a.ml', { kind: 'repository', repoId: 'masc', codebase: null }),
      selection: null,
      codebaseForRepo: repoId => (repoId === 'masc' ? 'github.com_jeong-sik_masc' : null),
    })
    expect(context?.fields).toContainEqual({ k: 'codebase', v: 'github.com_jeong-sik_masc' })
  })

  it('states codebase absence instead of omitting the field', () => {
    const context = buildIdeInterjectSurfaceContext({
      focus: focusOn('lib/a.ml', { kind: 'repository', repoId: 'localonly', codebase: null }),
      selection: null,
      codebaseForRepo: () => null,
    })
    const fields = (context?.fields ?? []) as ReadonlyArray<{ k: string; v: string }>
    const keys = fields.map(field => field.k)
    expect(keys).toContain('codebase_unavailable')
    expect(keys).not.toContain('codebase')
  })

  it('prefers the dispatch-time lookup over a stale identity snapshot', () => {
    const context = buildIdeInterjectSurfaceContext({
      focus: focusOn('lib/a.ml', { kind: 'repository', repoId: 'masc', codebase: null }),
      selection: null,
      codebaseForRepo: () => 'github.com_jeong-sik_masc',
    })
    expect(context?.fields).toContainEqual({ k: 'codebase', v: 'github.com_jeong-sik_masc' })
  })
  it('returns undefined when the IDE holds no anchor', () => {
    expect(buildIdeInterjectSurfaceContext({ focus: null, selection: null })).toBeUndefined()
  })

  it('returns undefined for a whitespace-only focus path', () => {
    expect(
      buildIdeInterjectSurfaceContext({ focus: focusOn('   '), selection: null }),
    ).toBeUndefined()
  })

  it('carries the focused file with the board-shaped envelope', () => {
    const context = buildIdeInterjectSurfaceContext({
      focus: focusOn('lib/web_dashboard.ml'),
      selection: null,
    })
    expect(context).toEqual({
      label: 'IDE interject context',
      route: '#code?section=ide-shell&file=lib%2Fweb_dashboard.ml',
      scene: 'ide_interject',
      fields: [
        { k: 'surface', v: 'ide' },
        { k: 'file', v: 'lib/web_dashboard.ml' },
      ],
    })
  })

  it('renders a single-line selection as one line marker', () => {
    const context = buildIdeInterjectSurfaceContext({
      focus: focusOn('lib/a.ml'),
      selection: { filePath: 'lib/a.ml', lineStart: 42, lineEnd: 42 },
    })
    expect(context?.fields).toContainEqual({ k: 'lines', v: 'L42' })
    expect(context?.route).toContain('line=42')
  })

  it('renders a range selection with both endpoints', () => {
    const context = buildIdeInterjectSurfaceContext({
      focus: focusOn('lib/a.ml'),
      selection: { filePath: 'lib/a.ml', lineStart: 3, lineEnd: 9 },
    })
    expect(context?.fields).toContainEqual({ k: 'lines', v: 'L3-L9' })
  })

  it('prefers the selection file over a stale focused tab', () => {
    const context = buildIdeInterjectSurfaceContext({
      focus: focusOn('lib/stale.ml'),
      selection: { filePath: 'lib/actual.ml', lineStart: 7, lineEnd: 8 },
    })
    expect(context?.fields).toContainEqual({ k: 'file', v: 'lib/actual.ml' })
    expect(context?.fields).not.toContainEqual({ k: 'file', v: 'lib/stale.ml' })
  })

  it('carries a repository workspace identity as repo', () => {
    const context = buildIdeInterjectSurfaceContext({
      focus: focusOn('lib/a.ml', { kind: 'repository', repoId: 'masc' }),
      selection: null,
    })
    expect(context?.fields).toContainEqual({ k: 'repo', v: 'masc' })
  })

  it('carries a keeper workspace identity as workspace_keeper', () => {
    const context = buildIdeInterjectSurfaceContext({
      focus: focusOn('lib/a.ml', { kind: 'keeper', keeper: 'nick0cave' }),
      selection: null,
    })
    expect(context?.fields).toContainEqual({ k: 'workspace_keeper', v: 'nick0cave' })
  })

  it('sends a selection anchor even without a focused tab', () => {
    const context = buildIdeInterjectSurfaceContext({
      focus: null,
      selection: { filePath: 'lib/only-selection.ml', lineStart: 1, lineEnd: 2 },
    })
    expect(context?.fields).toContainEqual({ k: 'file', v: 'lib/only-selection.ml' })
    expect(context?.fields).toContainEqual({ k: 'lines', v: 'L1-L2' })
  })
})
