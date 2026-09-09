import { html } from 'htm/preact'
import { render, cleanup } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import type { ToolCallEntry } from '../../api/dashboard'
import { ChatEditEvidence } from './edit-evidence'

afterEach(cleanup)
const receipt: ToolCallEntry = {
  ts: 1, keeper: 'writer', tool: 'Edit', success: true, duration_ms: 3,
  input: { old_string: 'old\nparagraph', new_string: '<b>new</b>\nparagraph' },
  output: JSON.stringify({ ok: true, mode: 'patch', path: 'essay.md', occurrences: 2 }),
  route_evidence: { descriptor_id: 'agent.edit_file' },
}

describe('recorded chat edit', () => {
  it('shows successful edit receipt and recorded input snippets with keyboard access', () => {
    const view = render(html`<${ChatEditEvidence} output=${receipt} />`)
    expect(view.getByText('essay.md · 2곳 편집')).toBeTruthy()
    expect(view.getByText(/비밀값 마스킹·길이 제한·앞뒤 공백 제거/)).toBeTruthy()
    const before = view.getByLabelText('기록된 찾기 입력 조각')
    const after = view.getByLabelText('기록된 바꾸기 입력 조각')
    expect(before.textContent).toBe('old\nparagraph')
    expect(after.textContent).toBe('<b>new</b>\nparagraph')
    expect(after.querySelector('b')).toBeNull()
    after.focus()
    expect(document.activeElement).toBe(after)
  })
  it('shows an empty recorded replacement without inferring exact file content', () => {
    const view = render(html`<${ChatEditEvidence} output=${{ ...receipt,
      input: { old_string: 'remove me', new_string: '' } }} />`)
    expect(view.getByLabelText('기록된 바꾸기 입력 조각').textContent).toBe('')
  })
  it('retains successful whitespace edits whose logged search input was trimmed empty', () => {
    const view = render(html`<${ChatEditEvidence} output=${{ ...receipt,
      input: { old_string: '', new_string: 'replacement' } }} />`)
    expect(view.getByText('essay.md · 2곳 편집')).toBeTruthy()
    expect(view.getByLabelText('기록된 찾기 입력 조각').textContent).toBe('')
  })
  it('displays redacted and shortened records as snippets with an omission note', () => {
    const view = render(html`<${ChatEditEvidence} output=${{ ...receipt,
      input: { old_string: '[REDACTED]', new_string: 'shortened…' } }} />`)
    expect(view.getByLabelText('기록된 찾기 입력 조각').textContent).toBe('[REDACTED]')
    expect(view.getByLabelText('기록된 바꾸기 입력 조각').textContent).toBe('shortened…')
    expect(view.getByText(/실제 파일 diff와 다를 수 있습니다/)).toBeTruthy()
  })
  it.each([
    null,
    { ...receipt, success: false },
    { ...receipt, route_evidence: undefined },
    { ...receipt, output: '{truncated' },
    { ...receipt, output: '{"ok":true,"approval_pending":true}' },
    { ...receipt, output: '{"ok":true,"mode":"patch","path":"essay.md","occurrences":0}' },
    { ...receipt, input: { old_string: 'old' } },
  ])('does not present unproven changes as applied', output => {
    const view = render(html`<${ChatEditEvidence} output=${output} />`)
    expect(view.queryByLabelText('편집 변경 기록')).toBeNull()
  })
})
