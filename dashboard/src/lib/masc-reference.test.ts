import { describe, it, expect } from 'vitest'
import {
  parseMascReference,
  scanMascReferences,
  postsSharingReferences,
} from './masc-reference'

// The wire forms here are the ones bin/masc_tui_link.ml writes. If that file
// changes a path, these fail — which is the point: two readers of one format
// drifting apart is how a link stops going where it says.
describe('parseMascReference', () => {
  it('reads each path the TUI writes', () => {
    expect(parseMascReference('masc://board/post-42')).toEqual({ kind: 'post', id: 'post-42' })
    expect(parseMascReference('masc://planning/goal-2')).toEqual({ kind: 'goal', id: 'goal-2' })
    expect(parseMascReference('masc://schedules/sch-1')).toEqual({ kind: 'schedule', id: 'sch-1' })
    expect(parseMascReference('masc://overview/tasks/task-7')).toEqual({ kind: 'task', id: 'task-7' })
    expect(parseMascReference('masc://fusion/run-9')).toEqual({ kind: 'run', id: 'run-9' })
    expect(parseMascReference('masc://keepers/kidsnote')).toEqual({ kind: 'keeper', id: 'kidsnote' })
  })

  it('decodes an id that needed escaping', () => {
    // The OCaml writer percent-encodes everything outside the unreserved set.
    expect(parseMascReference('masc://planning/goal%2Fone%20two')).toEqual({
      kind: 'goal',
      id: 'goal/one two',
    })
  })

  it('refuses what this program did not write', () => {
    // Each of these would otherwise become an id that names nothing.
    expect(parseMascReference('masc://unknown/thing')).toBeNull()
    expect(parseMascReference('masc://board/')).toBeNull()
    expect(parseMascReference('masc://board')).toBeNull()
    expect(parseMascReference('https://example.invalid/x')).toBeNull()
    expect(parseMascReference('masc://board/bad%zz')).toBeNull()
    expect(parseMascReference('masc://board/trailing%')).toBeNull()
    expect(parseMascReference('')).toBeNull()
  })
})

describe('scanMascReferences', () => {
  it('takes the real references, once each, in order', () => {
    const body = [
      'see masc://overview/tasks/task-7 and masc://planning/goal-2',
      'again masc://overview/tasks/task-7 (a repeat)',
      'task-99 is written out but never linked',
      'masc://nowhere/x is not a surface',
    ].join('\n')
    expect(scanMascReferences(body)).toEqual([
      { kind: 'task', id: 'task-7' },
      { kind: 'goal', id: 'goal-2' },
    ])
  })

  it('does not link an id that is merely spelled out', () => {
    // A connection the writer did not make is one nobody checked.
    expect(scanMascReferences('task-1 and goal-2 are mentioned in prose')).toEqual([])
    expect(scanMascReferences(null)).toEqual([])
    expect(scanMascReferences(undefined)).toEqual([])
  })

  it('stops a reference where a path segment cannot continue', () => {
    // Trailing punctuation belongs to the sentence, not the id.
    expect(scanMascReferences('see masc://board/post-42, then stop')).toEqual([
      { kind: 'post', id: 'post-42' },
    ])
  })
})

describe('postsSharingReferences', () => {
  const posts = [
    { id: 'p-1', body: 'about masc://overview/tasks/task-7' },
    { id: 'p-2', body: 'also masc://overview/tasks/task-7 plus masc://planning/goal-2' },
    { id: 'p-3', body: 'unrelated, mentions task-7 only in prose' },
    { id: 'p-4', body: 'only masc://planning/goal-9' },
  ]

  it('finds the posts pointing at the same thing', () => {
    expect(postsSharingReferences(posts[0]!, posts).map(p => p.id)).toEqual(['p-2'])
  })

  it('never relates a post to itself, and answers empty when it points at nothing', () => {
    expect(postsSharingReferences(posts[2]!, posts)).toEqual([])
    expect(postsSharingReferences(posts[3]!, posts)).toEqual([])
  })
})
