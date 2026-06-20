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
})
