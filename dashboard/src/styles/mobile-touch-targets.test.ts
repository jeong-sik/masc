import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

function css(file: string): string {
  return readFileSync(resolve(__dirname, file), 'utf8')
}

describe('operator surface mobile touch targets', () => {
  it.each([
    ['fusion-v2.css', '.fus-link'],
    ['work-v2.css', '.wk-task-claim'],
    ['board-v2.css', '.bd-react'],
    ['v2-logs.css', '.v2-logs-filter-chip'],
    ['keeper-v2/fleet.css', '.fl-create'],
    ['ide-v2.css', '.v2-ide-action'],
    ['v2-overview.css', '.v2-overview-surface button'],
    ['keeper-v2/schedule.css', '.sch-surf button'],
    ['approvals-v2.css', '.ap-surface button'],
    ['connectors-v2.css', '.v2-connectors-surface button'],
  ])('keeps %s primary controls at least 40px high (%s)', (file, selector) => {
    const source = css(file)
    const selectorRules = source.split(selector).slice(1)
    expect(selectorRules.length).toBeGreaterThan(0)
    expect(selectorRules.some(rule => /min-height:\s*40px/.test(rule.slice(0, 420)))).toBe(true)
  })

  it('covers board reaction choices and narrow icon actions in both dimensions', () => {
    const source = css('board-v2.css')
    expect(source).toMatch(/\.board-reaction-bar button\s*\{[^}]*min-width:\s*40px;[^}]*min-height:\s*40px;/)
    expect(source).toMatch(/\.bd-post-foot button\[aria-label\][^{]*\{[^}]*min-width:\s*40px;/)
  })

  it('wraps backend-owned Goal metrics and Board action rows at mobile width', () => {
    expect(css('work-v2.css')).toMatch(/\.wk-metric\s*\{[^}]*overflow-wrap:\s*anywhere;/)
    expect(css('board-v2.css')).toMatch(/\.v2-board-surface \.bd-post-foot\s*\{[^}]*flex-wrap:\s*wrap;/)
  })

  it('covers FSM Hub controls and Board selection labels', () => {
    expect(css('keeper-v2/fleet.css')).toMatch(/\.fsm-hub-surface button,[\s\S]*?min-height:\s*40px;/)
    expect(css('board-v2.css')).toMatch(/\.bd-post-select-target\s*\{[^}]*width:\s*40px;[^}]*height:\s*40px;/)
  })
})
