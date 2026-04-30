// Pure TS unit tests for CollaborationCursor. No DOM.
import { describe, it, expect } from 'vitest'
import { createAgentPresenceManager, type AgentDescriptor } from './agent-presence'
import {
  createCollaborationManager,
  type AgentCursor,
  type FileConflict,
} from './collaboration'

function agent(id: string, name: string): AgentDescriptor {
  return {
    id,
    name,
    sigil: { text: name.slice(0, 2).toUpperCase() },
    colorSlot: 1,
  }
}

function setupTwo(): {
  presence: ReturnType<typeof createAgentPresenceManager>
  collab: ReturnType<typeof createCollaborationManager>
} {
  const presence = createAgentPresenceManager({
    initialAgents: [agent('a', 'Alice'), agent('b', 'Bob')],
  })
  const collab = createCollaborationManager({ presence })
  return { presence, collab }
}

describe('createCollaborationManager — file scoping', () => {
  it('activeAgentsInFile returns only agents in that file', () => {
    const { presence, collab } = setupTwo()
    presence.updateCursor('a', 'src/foo.ts', 10, 5)
    presence.updateCursor('b', 'src/bar.ts', 20, 1)
    expect(collab.activeAgentsInFile('src/foo.ts').map((c) => c.agent.id)).toEqual([
      'a',
    ])
    expect(collab.activeAgentsInFile('src/bar.ts').map((c) => c.agent.id)).toEqual([
      'b',
    ])
    expect(collab.activeAgentsInFile('src/baz.ts')).toEqual([])
  })

  it('cursor clear removes agent from activeAgentsInFile', () => {
    const { presence, collab } = setupTwo()
    presence.updateCursor('a', 'src/foo.ts', 10, 5)
    expect(collab.activeAgentsInFile('src/foo.ts').length).toBe(1)
    presence.clearCursor('a')
    expect(collab.activeAgentsInFile('src/foo.ts').length).toBe(0)
  })
})

describe('createCollaborationManager — conflict detection', () => {
  it('two agents at same line: conflict on line ± radius', () => {
    const { presence, collab } = setupTwo()
    presence.updateCursor('a', 'f', 42, 1)
    presence.updateCursor('b', 'f', 42, 8)
    const cs = collab.conflictsInFile('f')
    expect(cs.length).toBe(1)
    expect(cs[0]!.lineFrom).toBe(41)
    expect(cs[0]!.lineTo).toBe(43)
    expect(cs[0]!.agents.map((a) => a.id).sort()).toEqual(['a', 'b'])
  })

  it('two agents in different files: no conflict', () => {
    const { presence, collab } = setupTwo()
    presence.updateCursor('a', 'fileA', 10, 1)
    presence.updateCursor('b', 'fileB', 10, 1)
    expect(collab.conflictsInFile('fileA')).toEqual([])
    expect(collab.conflictsInFile('fileB')).toEqual([])
  })

  it('conflictRadius 0 emits only on exact line match', () => {
    const presence = createAgentPresenceManager({
      initialAgents: [agent('a', 'Alice'), agent('b', 'Bob')],
    })
    const collab = createCollaborationManager({ presence, conflictRadius: 0 })
    presence.updateCursor('a', 'f', 42, 1)
    presence.updateCursor('b', 'f', 43, 1)
    expect(collab.conflictsInFile('f')).toEqual([])
    presence.updateCursor('b', 'f', 42, 5)
    const cs = collab.conflictsInFile('f')
    expect(cs.length).toBe(1)
    expect(cs[0]!.lineFrom).toBe(42)
    expect(cs[0]!.lineTo).toBe(42)
  })

  it('three agents overlapping: single conflict with 3 agents', () => {
    const presence = createAgentPresenceManager({
      initialAgents: [
        agent('a', 'A'),
        agent('b', 'B'),
        agent('c', 'C'),
      ],
    })
    const collab = createCollaborationManager({ presence })
    presence.updateCursor('a', 'f', 10, 1)
    presence.updateCursor('b', 'f', 11, 1)
    presence.updateCursor('c', 'f', 12, 1)
    const cs = collab.conflictsInFile('f')
    expect(cs.length).toBe(1)
    expect(cs[0]!.agents.length).toBe(3)
  })

  it('selection conflict: A line 10-20 + B line 18 → 9-21', () => {
    const { presence, collab } = setupTwo()
    presence.updateCursor('a', 'f', 10, 1)
    presence.updateCursor('b', 'f', 18, 1)
    collab.setSelection('a', 'f', {
      line: 10,
      column: 1,
      end: { line: 20, column: 1 },
    })
    const cs = collab.conflictsInFile('f')
    expect(cs.length).toBe(1)
    expect(cs[0]!.lineFrom).toBe(9)
    expect(cs[0]!.lineTo).toBe(21)
  })

  it('disjoint after move: conflict subscriber fires with empty list', () => {
    const { presence, collab } = setupTwo()
    presence.updateCursor('a', 'f', 10, 1)
    presence.updateCursor('b', 'f', 11, 1)
    const events: ReadonlyArray<FileConflict>[] = []
    collab.subscribeConflicts((cs) => events.push(cs))
    presence.updateCursor('b', 'f', 100, 1)
    // Last event should reflect the empty conflict set.
    expect(events.length).toBeGreaterThan(0)
    expect(events[events.length - 1]!.length).toBe(0)
  })
})

describe('createCollaborationManager — announceConflict text', () => {
  it('2 agents: "between A and B on lines N-M of <basename>"', () => {
    const { presence, collab } = setupTwo()
    presence.updateCursor('a', 'src/foo.ts', 42, 1)
    presence.updateCursor('b', 'src/foo.ts', 42, 8)
    const cs = collab.conflictsInFile('src/foo.ts')
    const ann = collab.announceConflict(cs[0]!)
    expect(ann.text).toBe(
      'Editing conflict between Alice and Bob on lines 41-43 of foo.ts',
    )
    expect(ann.assertive).toBe(true)
  })

  it('3+ agents: "and N other(s)" suffix', () => {
    const presence = createAgentPresenceManager({
      initialAgents: [
        agent('a', 'A'),
        agent('b', 'B'),
        agent('c', 'C'),
        agent('d', 'D'),
      ],
    })
    const collab = createCollaborationManager({ presence })
    presence.updateCursor('a', 'x.ts', 10, 1)
    presence.updateCursor('b', 'x.ts', 10, 2)
    presence.updateCursor('c', 'x.ts', 10, 3)
    presence.updateCursor('d', 'x.ts', 10, 4)
    const cs = collab.conflictsInFile('x.ts')
    const ann = collab.announceConflict(cs[0]!)
    expect(ann.text).toContain('A, B, and 2 others on lines 9-11 of x.ts')
  })

  it('single-line conflict: "line N" (singular)', () => {
    const presence = createAgentPresenceManager({
      initialAgents: [agent('a', 'A'), agent('b', 'B')],
    })
    const collab = createCollaborationManager({ presence, conflictRadius: 0 })
    presence.updateCursor('a', 'f', 10, 1)
    presence.updateCursor('b', 'f', 10, 5)
    const cs = collab.conflictsInFile('f')
    const ann = collab.announceConflict(cs[0]!)
    expect(ann.text).toBe('Editing conflict between A and B on line 10 of f')
  })
})

describe('createCollaborationManager — subscribe isolation', () => {
  it('subscribeFile: moves in file A do not fire listeners for file B', () => {
    const { presence, collab } = setupTwo()
    let aFires = 0
    let bFires = 0
    collab.subscribeFile('fileA', () => {
      aFires += 1
    })
    collab.subscribeFile('fileB', () => {
      bFires += 1
    })
    presence.updateCursor('a', 'fileA', 10, 1)
    expect(aFires).toBeGreaterThan(0)
    const aBaseline = aFires
    presence.updateCursor('b', 'fileA', 20, 1)
    // fileB listener untouched by fileA work.
    expect(bFires).toBe(0)
    expect(aFires).toBeGreaterThan(aBaseline)
  })

  it('subscribeConflicts: fires only on conflict-set change', () => {
    const { presence, collab } = setupTwo()
    let fires = 0
    collab.subscribeConflicts(() => {
      fires += 1
    })
    // Both move into same file but at far-apart lines → no conflict.
    presence.updateCursor('a', 'f', 10, 1)
    presence.updateCursor('b', 'f', 100, 1)
    const before = fires
    // Continuous typing in cursor A — line stays 10, column changes.
    presence.updateCursor('a', 'f', 10, 5)
    presence.updateCursor('a', 'f', 10, 6)
    presence.updateCursor('a', 'f', 10, 7)
    // Conflict set unchanged: still empty. Listener should not fire.
    expect(fires).toBe(before)
  })
})

describe('createCollaborationManager — selection lifecycle', () => {
  it('clearSelection drops selection and re-emits file', () => {
    const { presence, collab } = setupTwo()
    presence.updateCursor('a', 'f', 10, 1)
    collab.setSelection('a', 'f', {
      line: 10,
      column: 1,
      end: { line: 15, column: 1 },
    })
    let captured: ReadonlyArray<AgentCursor> = []
    collab.subscribeFile('f', (c) => {
      captured = c
    })
    collab.clearSelection('a')
    // After clear, subscribeFile listener should have observed the cursor
    // without selection.
    expect(captured.length).toBe(1)
    expect(captured[0]!.selection).toBeUndefined()
  })
})
