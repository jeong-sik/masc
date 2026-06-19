// @vitest-environment happy-dom
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const cssPath = resolve(__dirname, 'chat-blocks-v2.css')
const css = readFileSync(cssPath, 'utf-8')

function parseBlock(selector: string): Record<string, string> {
  const start = css.indexOf(selector)
  if (start === -1) {
    throw new Error(`Selector not found: ${selector}`)
  }

  const open = css.indexOf('{', start)
  const close = css.indexOf('}', open)
  const block = css.slice(open + 1, close)
  const props: Record<string, string> = {}
  for (const line of block.split('\n')) {
    const trimmed = line.trim()
    if (!trimmed || trimmed.startsWith('/*')) continue
    const match = /^([\w-]+):\s*([^;]+);/.exec(trimmed)
    if (match && match[1] && match[2]) {
      props[match[1]] = match[2].trim()
    }
  }
  return props
}

describe('chat-blocks-v2.css', () => {
  it('keeps opened tool traces from shrinking inside the chat flex column', () => {
    const trace = parseBlock('.chat-block-trace')
    expect(trace.display).toBe('flex')
    expect(trace.flex).toBe('none')
    expect(trace['flex-direction']).toBe('column')
  })
})
