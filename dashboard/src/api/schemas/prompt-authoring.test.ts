import { describe, expect, it } from 'vitest'
import { parsePromptAuthoringIssues } from './prompt-authoring'

const issue = {
  code: 'invalid_operator_surface',
  field: 'operator_surface',
  value: 'primray',
  source_file: '/workspace/.masc/prompts/keeper.md',
}

describe('prompt authoring diagnostics at the wire boundary', () => {
  it('preserves a clean report and authored errors', () => {
    expect(parsePromptAuthoringIssues([])).toEqual([])
    expect(parsePromptAuthoringIssues([issue])).toEqual([issue])
    expect(parsePromptAuthoringIssues([{ ...issue, value: '' }])[0]?.value).toBe('')
  })

  it('refuses unknown or malformed reports rather than hiding their errors', () => {
    for (const raw of [undefined, null, {}, [null], [{ ...issue, code: 'unknown' }],
      [{ ...issue, field: 'other' }], [{ ...issue, value: 3 }],
      [{ code: issue.code, field: issue.field, value: issue.value }]]) {
      expect(() => parsePromptAuthoringIssues(raw)).toThrow()
    }
  })
})
