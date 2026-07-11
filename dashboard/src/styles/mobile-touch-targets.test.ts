import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { parse } from 'postcss'
import { describe, expect, it } from 'vitest'
import { declarationsForSelector } from './css-test-utils'

function css(file: string): string {
  return readFileSync(resolve(__dirname, file), 'utf8')
}

function declarationsInMedia(file: string, selector: string, condition: string): Record<string, string> {
  const blocks: string[] = []
  parse(css(file)).walkAtRules('media', (rule) => {
    if (rule.params === condition) blocks.push(rule.toString())
  })
  if (blocks.length === 0) throw new Error(`Media rule not found: ${condition}`)
  return declarationsForSelector(blocks.join('\n'), selector)
}

describe('operator surface mobile touch targets', () => {
  const target = 'var(--mobile-touch-target-min)'

  it.each([
    ['fusion-v2.css', '.v2-fusion-surface .fus-link'],
    ['work-v2.css', '.wk-task-claim'],
    ['board-v2.css', '.v2-board-surface .bd-react'],
    ['v2-logs.css', '.v2-logs-filter-chip'],
    ['keeper-v2/fleet.css', '.fl-create'],
    ['ide-v2.css', '.ide-plane-shell[data-mobile-viewport="true"] .v2-ide-action'],
    ['v2-overview.css', '.v2-overview-surface button'],
    ['keeper-v2/schedule.css', '.sch-surf button'],
    ['approvals-v2.css', '.ap-surface button'],
    ['connectors-v2.css', '.v2-connectors-surface button'],
  ])('binds %s primary controls to the mobile target token (%s)', (file, selector) => {
    expect(declarationsForSelector(css(file), selector)['min-height']).toBe(target)
  })

  it.each([
    ['keeper-v2/v2.css', '.v2-statchip'],
    ['keeper-v2/v2.css', '.attn-row'],
    ['board-v2.css', '.bd-author-action'],
    ['board-v2.css', '.bd-comment-filter'],
    ['board-v2.css', '.board-comment .v2-workspace-action'],
    ['board-v2.css', '.v2-workspace-surface .bd-summary .bd-summary-action'],
    ['board-v2.css', '.bd-share-action'],
    ['board-v2.css', '.bd-meta-summary'],
    ['v2-logs.css', '.v2-logs-inline-links .logs-route-link'],
    ['ide-v2.css', '.ide-plane-shell[data-mobile-viewport="true"] button.ide-remote'],
    ['ide-v2.css', '.ide-plane-shell[data-mobile-viewport="true"] a.ide-web'],
    ['base.css', '.rich-composer-tab'],
  ])('binds %s discrete actions to the token in both dimensions (%s)', (file, selector) => {
    const declarations = declarationsForSelector(css(file), selector)
    expect(declarations['min-width']).toBe(target)
    expect(declarations['min-height']).toBe(target)
  })

  it('positions the attention menu below the enlarged mobile trigger', () => {
    expect(declarationsForSelector(css('keeper-v2/v2.css'), '.attn-menu').top)
      .toBe('calc(100% + var(--sp-1h))')
  })

  it('keeps tablet-width Logs drill-down actions inside the mobile contract', () => {
    for (const selector of [
      '.v2-logs-inline-links .logs-route-link',
      '.logs-hide-fsm-label',
      '.logs-auto-label',
    ]) {
      const declarations = declarationsInMedia('v2-logs.css', selector, '(max-width: 900px)')
      expect(declarations['min-width']).toBe(target)
      expect(declarations['min-height']).toBe(target)
      if (selector === '.logs-hide-fsm-label' || selector === '.logs-auto-label') {
        expect(declarations['touch-action']).toBe('manipulation')
      }
    }
  })

  it('keeps Settings navigation on the canonical target token', () => {
    expect(declarationsInMedia('settings-surface.css', '.set-nav-item', '(max-width: 900px)')['min-height'])
      .toBe(target)
  })

  it('binds generic controls to the typed runtime mobile scope', () => {
    const source = css('mobile-operator-targets.css')
    for (const selector of [
      '.v2-app[data-mobile="1"] button',
      '.v2-app[data-mobile="1"] summary',
      '.v2-app[data-mobile="1"] select',
      '.v2-app[data-mobile="1"] textarea',
      '.v2-app[data-mobile="1"] input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"])',
      '.v2-app[data-mobile="1"] .v2-mobile-operator-target',
    ]) {
      const declarations = declarationsForSelector(source, selector)
      expect(declarations['min-width']).toBe(target)
      expect(declarations['min-height']).toBe(target)
    }
    expect(declarationsForSelector(source, '.v2-app[data-mobile="1"] .v2-mobile-operator-target')['touch-action'])
      .toBe('manipulation')
    expect(declarationsForSelector(source, '.v2-app[data-mobile="1"] .v2-mobile-operator-target'))
      .not.toHaveProperty('display')
  })

  it('covers board reaction choices and narrow icon actions in both dimensions', () => {
    const source = css('board-v2.css')
    const reaction = declarationsForSelector(source, '.board-reaction-bar button')
    const iconAction = declarationsForSelector(source, '.v2-board-surface .bd-post-foot button[aria-label]')
    expect(reaction['min-width']).toBe(target)
    expect(reaction['min-height']).toBe(target)
    expect(iconAction['min-width']).toBe(target)
  })

  it('wraps backend-owned Goal metrics and Board action rows at mobile width', () => {
    expect(declarationsForSelector(css('work-v2.css'), '.wk-metric')['overflow-wrap']).toBe('anywhere')
    expect(declarationsForSelector(css('board-v2.css'), '.v2-board-surface .bd-post-foot')['flex-wrap']).toBe('wrap')
  })

  it('covers FSM Hub controls and Board selection labels', () => {
    const fsmButton = declarationsForSelector(css('keeper-v2/fleet.css'), '.fsm-hub-surface button')
    const selection = declarationsForSelector(css('board-v2.css'), '.v2-board-surface .bd-post-select-target')
    expect(fsmButton['min-width']).toBe(target)
    expect(fsmButton['min-height']).toBe(target)
    expect(selection.width).toBe(target)
    expect(selection.height).toBe(target)
    expect(selection['touch-action']).toBe('manipulation')
  })
})
