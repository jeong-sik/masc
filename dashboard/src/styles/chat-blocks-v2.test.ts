// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { declarationsForSelector } from './css-test-utils'

const cssPath = resolve(__dirname, 'chat-blocks-v2.css')
const css = readFileSync(cssPath, 'utf-8')

describe('chat-blocks-v2.css', () => {
  it('keeps opened tool traces from shrinking inside the chat flex column', () => {
    const trace = declarationsForSelector(css, '.chat-block-trace')
    expect(trace.display).toBe('flex')
    expect(trace.flex).toBe('none')
    expect(trace['flex-direction']).toBe('column')
  })

  it('truncates a tool row subject instead of wrapping the row', () => {
    const subject = declarationsForSelector(css, '.chat-block-tstep-subject')
    expect(subject.flex).toBe('1 1 auto')
    expect(subject['min-width']).toBe('0')
    expect(subject.overflow).toBe('hidden')
    expect(subject['white-space']).toBe('nowrap')
    expect(subject['text-overflow']).toBe('ellipsis')
  })

  it('indents tool rows under a branch line so a run reads as one turn', () => {
    const tool = declarationsForSelector(css, '.chat-block-tstep.tool')
    expect(tool['margin-left']).toBe('13px')
    expect(tool['border-left']).toBe('1px solid var(--color-border-default)')
  })

  it('closes the gap between consecutive tool rows so the branch line is continuous', () => {
    const run = declarationsForSelector(css, '.chat-block-tstep.tool + .chat-block-tstep.tool')
    expect(run['margin-top']).toBe('0')
  })

  it('hangs each step off the rail instead of leaving it floating beside it', () => {
    const branch = declarationsForSelector(css, '.chat-block-tnode::before')
    expect(branch.position).toBe('absolute')
    expect(branch.right).toBe('100%')
    expect(branch.height).toBe('1px')
  })

  it('truncates a collapsed run header summary rather than growing the header', () => {
    const tools = declarationsForSelector(css, '.chat-block-trace-tools')
    expect(tools.flex).toBe('1 1 auto')
    expect(tools['min-width']).toBe('0')
    expect(tools['white-space']).toBe('nowrap')
    expect(tools['text-overflow']).toBe('ellipsis')
  })

  it('keeps work trace and answer in one fixed-width turn bundle', () => {
    const bundle = declarationsForSelector(css, '.chat-turn-bundle')
    expect(bundle.display).toBe('flex')
    expect(bundle.flex).toBe('none')
    expect(bundle['flex-direction']).toBe('column')
    expect(bundle['align-self']).toBe('flex-start')
    expect(bundle.width).toBe('82%')
  })
})
