import { describe, expect, it } from 'vitest'

import { toolDisplayLabel } from './tool-display-label.ts'

describe('toolDisplayLabel', () => {
  it('reads snake wire names as Pascal labels', () => {
    expect(toolDisplayLabel('keeper_task_done')).toBe('KeeperTaskDone')
    expect(toolDisplayLabel('masc_board_post')).toBe('MascBoardPost')
    expect(toolDisplayLabel('keeper_memory_search')).toBe('KeeperMemorySearch')
  })

  it('passes skill slugs through unchanged', () => {
    expect(toolDisplayLabel('browser-lanes')).toBe('browser-lanes')
    expect(toolDisplayLabel('msx-play')).toBe('msx-play')
  })

  it('keeps Pascal names and labels single words', () => {
    expect(toolDisplayLabel('WebFetch')).toBe('WebFetch')
    expect(toolDisplayLabel('shell')).toBe('Shell')
  })

  it('lifts only ASCII a-z so the mirror stays byte-faithful on non-ASCII input', () => {
    // task-2327: unregistered inputs carry no ASCII promise (skill slugs pass
    // package_id_of_directory, MCP names come from outside the process), and
    // toUpperCase() would lift 'ü' where String.capitalize_ascii leaves it.
    // Both sides must render the same bytes for any input.
    expect(toolDisplayLabel('über_agent')).toBe('überAgent')
    expect(toolDisplayLabel('ünïcode_名')).toBe('ünïcode名')
    expect(toolDisplayLabel('Ωmega')).toBe('Ωmega')
  })

  it('is injective on the name shapes in use', () => {
    const names = [
      'keeper_task_done',
      'masc_board_post',
      'keeper_memory_search',
      'WebFetch',
      'browser-lanes',
      'shell',
    ]
    const labels = names.map(toolDisplayLabel)
    expect(new Set(labels).size).toBe(labels.length)
  })
})
