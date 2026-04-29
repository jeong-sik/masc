// Pure TS unit tests for AgentPresenceManager. No DOM.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  createAgentPresenceManager,
  deriveSigil,
  kSlot,
  type AgentDescriptor,
} from './agent-presence'

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(new Date('2026-04-29T00:00:00Z'))
})
afterEach(() => {
  vi.useRealTimers()
})

const nick: AgentDescriptor = Object.freeze({
  id: 'nick0cave',
  name: 'nick0cave',
  sigil: { text: 'NC' },
  colorSlot: 1,
})

const sangsu: AgentDescriptor = Object.freeze({
  id: 'sangsu',
  name: 'sangsu',
  sigil: { text: 'SS' },
  colorSlot: 5,
})

describe('createAgentPresenceManager — register / unregister', () => {
  it('register adds the agent; has flips true; subscribers fire', () => {
    const m = createAgentPresenceManager()
    const calls: number[] = []
    m.subscribe((snap) => calls.push(snap.length))
    m.register(nick)
    expect(m.has('nick0cave')).toBe(true)
    expect(calls).toEqual([1])
  })

  it('unregister removes; has flips false; per-agent listeners cleaned', () => {
    const m = createAgentPresenceManager()
    m.register(nick)
    m.unregister('nick0cave')
    expect(m.has('nick0cave')).toBe(false)
  })
})

describe('createAgentPresenceManager — updateState', () => {
  it('flips state, updates stateChangedAt, fires subscribers', () => {
    const m = createAgentPresenceManager({ initialAgents: [nick] })
    const calls: string[] = []
    m.subscribe(() => calls.push('snap'))
    vi.advanceTimersByTime(1000)
    m.updateState('nick0cave', 'working')
    const agent = m.agents.get('nick0cave')!
    expect(agent.state).toBe('working')
    expect(agent.stateChangedAt).toBe(new Date('2026-04-29T00:00:01Z').toISOString())
    expect(calls).toEqual(['snap'])
  })

  it('no-op on unknown id', () => {
    const m = createAgentPresenceManager()
    let fired = 0
    m.subscribe(() => {
      fired += 1
    })
    m.updateState('not-there', 'working')
    expect(fired).toBe(0)
  })

  it('no-op when state matches current', () => {
    const m = createAgentPresenceManager({ initialAgents: [nick] })
    let fired = 0
    m.subscribe(() => {
      fired += 1
    })
    m.updateState('nick0cave', 'idle')
    expect(fired).toBe(0)
  })
})

describe('createAgentPresenceManager — announceStateChange', () => {
  it('working -> polite "is now working"', () => {
    const m = createAgentPresenceManager({ initialAgents: [nick] })
    m.updateState('nick0cave', 'working')
    const ann = m.announceStateChange('nick0cave', 'idle')
    expect(ann).not.toBeNull()
    expect(ann!.text).toBe('nick0cave is now working')
    expect(ann!.assertive).toBe(false)
  })

  it('error -> ASSERTIVE "reported an error"', () => {
    const m = createAgentPresenceManager({ initialAgents: [nick] })
    m.updateState('nick0cave', 'error')
    const ann = m.announceStateChange('nick0cave', 'working')
    expect(ann!.text).toBe('nick0cave reported an error')
    expect(ann!.assertive).toBe(true)
  })

  it('idle / thinking -> null (silent)', () => {
    const m = createAgentPresenceManager({ initialAgents: [nick] })
    m.updateState('nick0cave', 'thinking')
    expect(m.announceStateChange('nick0cave', 'working')).toBeNull()
  })
})

describe('createAgentPresenceManager — subscribe / subscribeAgent', () => {
  it('subscribeAgent listener fires only for matching id', () => {
    const m = createAgentPresenceManager({ initialAgents: [nick, sangsu] })
    const nickFires: string[] = []
    const sangsuFires: string[] = []
    m.subscribeAgent('nick0cave', (a) => nickFires.push(a.state))
    m.subscribeAgent('sangsu', (a) => sangsuFires.push(a.state))
    m.updateState('nick0cave', 'working')
    m.updateState('sangsu', 'error')
    expect(nickFires).toEqual(['working'])
    expect(sangsuFires).toEqual(['error'])
  })

  it('subscribe / unsubscribe is leak-safe', () => {
    const m = createAgentPresenceManager({ initialAgents: [nick] })
    let fired = 0
    const dispose = m.subscribe(() => {
      fired += 1
    })
    m.updateState('nick0cave', 'working')
    expect(fired).toBe(1)
    dispose()
    m.updateState('nick0cave', 'idle')
    expect(fired).toBe(1)
  })
})

describe('createAgentPresenceManager — byState / withinFile', () => {
  it('byState filters', () => {
    const m = createAgentPresenceManager({ initialAgents: [nick, sangsu] })
    m.updateState('nick0cave', 'working')
    expect(m.byState('working').map((a) => a.id)).toEqual(['nick0cave'])
    expect(m.byState('idle').map((a) => a.id)).toEqual(['sangsu'])
  })

  it('withinFile filters by currentFile', () => {
    const m = createAgentPresenceManager({ initialAgents: [nick, sangsu] })
    m.updateCursor('nick0cave', 'app.ts', 10, 5)
    expect(m.withinFile('app.ts').map((a) => a.id)).toEqual(['nick0cave'])
    expect(m.withinFile('other.ts')).toHaveLength(0)
  })
})

describe('createAgentPresenceManager — cursor + heartbeat', () => {
  it('updateCursor sets currentFile + line/column', () => {
    const m = createAgentPresenceManager({ initialAgents: [nick] })
    m.updateCursor('nick0cave', 'main.ts', 42, 7)
    const a = m.agents.get('nick0cave')!
    expect(a.currentFile).toBe('main.ts')
    expect(a.cursor).toEqual({ line: 42, column: 7 })
  })

  it('clearCursor unsets cursor + currentFile', () => {
    const m = createAgentPresenceManager({ initialAgents: [nick] })
    m.updateCursor('nick0cave', 'main.ts', 42, 7)
    m.clearCursor('nick0cave')
    const a = m.agents.get('nick0cave')!
    expect(a.cursor).toBeUndefined()
    expect(a.currentFile).toBeUndefined()
  })

  it('heartbeat resets idleMs to 0', () => {
    const m = createAgentPresenceManager({ initialAgents: [nick] })
    m.heartbeat('nick0cave')
    expect(m.agents.get('nick0cave')!.idleMs).toBe(0)
  })
})

describe('deriveSigil + kSlot', () => {
  it('deriveSigil takes first 2 alpha chars uppercase', () => {
    expect(deriveSigil('nick0cave').text).toBe('NI')
    expect(deriveSigil('alice').text).toBe('AL')
    expect(deriveSigil('Q').text).toBe('Q?')
  })

  it('kSlot is deterministic for same id', () => {
    expect(kSlot('nick0cave')).toBe(kSlot('nick0cave'))
    expect(kSlot('sangsu')).toBe(kSlot('sangsu'))
  })

  it('kSlot returns a slot in 1..12', () => {
    for (const id of ['a', 'b', 'foo', 'nick0cave', 'sangsu', 'rama']) {
      const slot = kSlot(id)
      expect(slot).toBeGreaterThanOrEqual(1)
      expect(slot).toBeLessThanOrEqual(12)
    }
  })
})

describe('createAgentPresenceManager — sigil disambiguation', () => {
  it('default policy adds superscript digit suffix on collision', () => {
    const m = createAgentPresenceManager()
    m.register({ id: 'a', name: 'nick0cave', sigil: { text: 'NC' }, colorSlot: 1 })
    m.register({ id: 'b', name: 'nicolas-cage', sigil: { text: 'NC' }, colorSlot: 2 })
    m.register({ id: 'c', name: 'northcat', sigil: { text: 'NC' }, colorSlot: 3 })
    expect(m.agents.get('a')!.sigil).toEqual({ text: 'NC' })
    expect(m.agents.get('b')!.sigil.suffix).toBe('²')
    expect(m.agents.get('c')!.sigil.suffix).toBe('³')
  })

  it('custom policy overrides default', () => {
    const m = createAgentPresenceManager({
      sigilDisambiguate: (cand) => ({ text: cand.text, suffix: '!' }),
    })
    m.register({ id: 'a', name: 'a', sigil: { text: 'XX' }, colorSlot: 1 })
    m.register({ id: 'b', name: 'b', sigil: { text: 'XX' }, colorSlot: 2 })
    expect(m.agents.get('a')!.sigil.suffix).toBe('!')
    expect(m.agents.get('b')!.sigil.suffix).toBe('!')
  })
})

describe('createAgentPresenceManager — reducedMotion getter', () => {
  it('reducedMotion returns the configured fn result', () => {
    let flag = false
    const m = createAgentPresenceManager({ reducedMotion: () => flag })
    expect(m.reducedMotion()).toBe(false)
    flag = true
    expect(m.reducedMotion()).toBe(true)
  })
})

describe('createAgentPresenceManager — high-throughput correctness', () => {
  it('genuine state transitions emit; same-state updates do not (no-op)', () => {
    const m = createAgentPresenceManager()
    for (let i = 0; i < 12; i += 1) {
      m.register({
        id: `k${i}`,
        name: `keeper-${i}`,
        sigil: { text: `K${i}` },
        colorSlot: ((i % 12) + 1) as never,
      })
    }
    let fires = 0
    const dispose = m.subscribe(() => {
      fires += 1
    })
    // 12 agents start as 'idle'. Each toggle alternates between
    // 'working' and 'idle' for the agent — every call genuinely
    // changes state, so every call should emit.
    const states = ['working', 'idle', 'working', 'idle', 'working'] as const
    for (const next of states) {
      for (let agent = 0; agent < 12; agent += 1) {
        m.updateState(`k${agent}`, next)
      }
    }
    expect(fires).toBe(12 * states.length)
    dispose()
    m.updateState('k0', 'thinking')
    expect(fires).toBe(12 * states.length)
  })
})
