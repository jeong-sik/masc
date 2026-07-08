import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

const SOURCE = resolve(__dirname, 'task-detail-overlay.ts')

describe('TaskDetailOverlay source class hygiene', () => {
  it('uses a valid rounded top utility on the sticky header', () => {
    const src = readFileSync(SOURCE, 'utf-8')
    expect(src).toContain('rounded-t-[var(--r-1)]')
    expect(src).not.toContain('rounded-[var(--r-1)]-t-2xl')
  })

  it('renders the predecessor lineage section in the overview (RFC-0323 G-9)', () => {
    const src = readFileSync(SOURCE, 'utf-8')
    expect(src).toContain('function PredecessorSection')
    expect(src).toContain('task.predecessor_task_id')
    // Wired into the overview body, not just defined.
    expect(src).toMatch(/PredecessorSection}\s+task=/)
    // Opens the predecessor's own detail when it is in the loaded list.
    expect(src).toContain('openTaskDetail(predecessor)')
  })
})
