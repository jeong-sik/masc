import { html } from 'htm/preact'
import { render, cleanup } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import type { ToolCallEntry } from '../../api/dashboard-keeper-tool-calls'
import { PublishedArtifactCard } from './published-artifact-card'

afterEach(cleanup)
const id = `artifact-${'a'.repeat(32)}`
const receipt: ToolCallEntry = {
  ts: 1, keeper: 'writer', tool: 'keeper_artifact_publish', input: {}, wire_outcome: 'ok', duration_ms: 1,
  execution_id: 'exact-execution', route_evidence: { descriptor_id: 'keeper.artifact.publish' },
  output: JSON.stringify({ schema: 'masc.published_artifact.v1', revision_url: 'https://untrusted.invalid',
    artifact: { id, revision: 2, title: '연구 결과', summary: '보고서가 저장됐습니다.', author: 'writer',
      created_at: '2026-10-19T01:00:00Z', format: 'markdown', task_id: null, goal_id: null, url: 'https://untrusted.invalid' } }),
}
describe('published report conversation card', () => {
  it('links an exact successful publication to its immutable local revision', () => {
    const view = render(html`<${PublishedArtifactCard} output=${receipt} />`)
    const link = view.getByRole('link', { name: '아티팩트 열기: 연구 결과' })
    expect(link.getAttribute('href')).toBe(`/dashboard/#/workspace?section=artifacts&artifact=${id}&revision=2`)
    expect(view.getByText('보고서가 저장됐습니다.')).toBeTruthy()
  })
  it.each([null, { ...receipt, wire_outcome: 'error' }, { ...receipt, disposition: 'deferred' },
    { ...receipt, route_evidence: undefined }, { ...receipt, route_evidence: { descriptor_id: 'agent.write_file' } },
  ] as (ToolCallEntry | null)[])('does not fabricate a publication for an ineligible result', output => {
    const view = render(html`<${PublishedArtifactCard} output=${output} />`)
    expect(view.queryByRole('link')).toBeNull()
  })
  it('reports a truncated or malformed publication without creating a broken link', () => {
    const view = render(html`<${PublishedArtifactCard} output=${{ ...receipt, output: '{truncated' }} />`)
    expect(view.getByRole('alert').textContent).toContain('문서 링크를 읽지 못했습니다')
    expect(view.queryByRole('link')).toBeNull()
  })
})
