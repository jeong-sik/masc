import { describe, expect, it } from 'vitest'
import { parseWorkspaceSource } from './workspace-source'

describe('parseWorkspaceSource', () => {
  it('treats null header as project', () => {
    expect(parseWorkspaceSource(null)).toEqual({ kind: 'project' })
  })

  it('treats empty header as project', () => {
    expect(parseWorkspaceSource('')).toEqual({ kind: 'project' })
  })

  it('decodes plain "project" tag', () => {
    expect(parseWorkspaceSource('project')).toEqual({ kind: 'project' })
  })

  it('decodes "repository:<id>"', () => {
    expect(parseWorkspaceSource('repository:masc'))
      .toEqual({ kind: 'repository', repoId: 'masc' })
  })

  it('decodes repository fallback variants', () => {
    expect(parseWorkspaceSource('repository_missing:masc'))
      .toEqual({ kind: 'repository_missing', repoId: 'masc' })
    expect(parseWorkspaceSource('repository_unknown:ghost'))
      .toEqual({ kind: 'repository_unknown', repoId: 'ghost' })
  })

  it('decodes "playground:<name>"', () => {
    expect(parseWorkspaceSource('playground:alpha'))
      .toEqual({ kind: 'playground', keeper: 'alpha' })
  })

  it('decodes "playground_missing:<name>"', () => {
    expect(parseWorkspaceSource('playground_missing:alpha'))
      .toEqual({ kind: 'playground_missing', keeper: 'alpha' })
  })

  it('decodes "keeper_unknown:<name>"', () => {
    expect(parseWorkspaceSource('keeper_unknown:ghost'))
      .toEqual({ kind: 'keeper_unknown', keeper: 'ghost' })
  })

  it('preserves colons inside the keeper name', () => {
    // Keeper names should not contain ':', but the parser splits on
    // the first colon only so any trailing colons stay in the name.
    expect(parseWorkspaceSource('playground:weird:name'))
      .toEqual({ kind: 'playground', keeper: 'weird:name' })
  })

  it('falls back to project for unknown tags', () => {
    expect(parseWorkspaceSource('unrecognized:foo'))
      .toEqual({ kind: 'project' })
  })

  it('falls back to project when no colon and not "project"', () => {
    expect(parseWorkspaceSource('garbage'))
      .toEqual({ kind: 'project' })
  })
})
