import { html } from 'htm/preact'
import { cleanup, fireEvent, render } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import {
  StructuredPayloadView,
  parseStructuredPayload,
  shouldDefaultCollapse,
  splitHeadTailPreview,
  summarizePayload,
} from './structured-payload'

describe('StructuredPayloadView', () => {
  afterEach(() => {
    cleanup()
  })

  it('parses JSON strings and computes collapse thresholds and head+tail previews', () => {
    const parsed = parseStructuredPayload('{"a":1,"b":[2,3]}')
    expect(parsed.isJson).toBe(true)
    expect(parsed.lines).toBeGreaterThan(1)
    expect(summarizePayload(parsed.parsed, parsed.formatted)).toBe('{ a, b }')

    expect(shouldDefaultCollapse('short line')).toBe(false)
    expect(shouldDefaultCollapse('x'.repeat(601))).toBe(true)
    expect(shouldDefaultCollapse(Array.from({ length: 9 }, (_, i) => `l${i}`).join('\n'))).toBe(true)

    const longStr = `${'A'.repeat(3000)}${'B'.repeat(3000)}`
    const preview = splitHeadTailPreview(longStr, 4096)
    expect(preview.truncated).toBe(true)
    expect(preview.head.length).toBe(2048)
    expect(preview.tail.length).toBe(2048)
    expect(preview.omittedChars).toBe(6000 - 4096)
  })

  it('default-collapses payloads exceeding threshold and toggles Tree/Raw/Wrap cleanly', () => {
    const largeInput = {
      path: 'lib/keeper/keeper_agent_run.ml',
      payload: 'Z'.repeat(700),
    }

    const view = render(
      html`
        <${StructuredPayloadView}
          value=${largeInput}
          label="Input (Args)"
          bodyTestId="payload-body"
        />
      `,
    )

    // Collapsed by default because formatted JSON > 600 chars
    expect(view.container.querySelector('[data-testid="structured-payload"]')?.getAttribute('data-collapsed')).toBe('true')
    const previewBtn = view.getByTestId('payload-body-preview')
    expect(previewBtn.textContent).toContain('{ path, payload }')

    // Click preview to expand into Tree view
    fireEvent.click(previewBtn)
    expect(view.container.querySelector('[data-testid="structured-payload"]')?.getAttribute('data-collapsed')).toBe('false')
    expect(view.getByTestId('payload-body').textContent).toContain('lib/keeper/keeper_agent_run.ml')

    // Switch to Raw mode and toggle Wrap
    fireEvent.click(view.getByTestId('spv-mode-raw'))
    const pre = view.getByTestId('payload-body')
    expect(pre.classList.contains('spv-pre--wrap')).toBe(true)
    fireEvent.click(view.getByTestId('spv-wrap-toggle'))
    expect(pre.classList.contains('spv-pre--nowrap')).toBe(true)
  })

  it('paginates large arrays and truncates strings > 4KB with head+tail preview in Tree mode', () => {
    const bigArray = Array.from({ length: 65 }, (_, i) => i)
    const hugeString = `${'H'.repeat(2500)}${'T'.repeat(2500)}`

    const view = render(
      html`
        <${StructuredPayloadView}
          value=${{ items: bigArray, big: hugeString }}
          defaultCollapsed=${false}
          defaultMode="tree"
          arrayPageSize=${50}
          maxStringPreviewChars=${4096}
        />
      `,
    )

    // 4KB string preview is truncated with an expand button
    expect(view.getByTestId('spv-truncated-string').textContent).toContain('자 생략')
    fireEvent.click(view.getByTestId('spv-expand-string'))
    expect(view.queryByTestId('spv-truncated-string')).toBeNull()

    // Array pagination button loads remaining 15 items
    const moreBtn = view.getByTestId('spv-array-more')
    expect(moreBtn.textContent).toContain('남은 15개')
    fireEvent.click(moreBtn)
    expect(view.queryByTestId('spv-array-more')).toBeNull()
  })
})
