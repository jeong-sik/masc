import { render } from 'preact'
import { useRef, useState } from 'preact/hooks'
import { html } from 'htm/preact'
import { ArtifactImport } from '../../src/components/published-artifacts/artifact-import'
import { ArtifactWordExport } from '../../src/components/published-artifacts/artifact-word-export'
import type { ArtifactDraftSnapshot } from '../../src/components/published-artifacts/artifact-composer'
import { currentStoredTokenRevision, setStoredToken } from '../../src/api/core'
import type { ArtifactDocument, ArtifactDraft } from '../../src/api/published-artifacts'
import { artifactAppFrame } from '../../src/lib/artifact-app-frame'
import { officeChartFigure } from '../../src/lib/artifact-office-chart'

// This isolated fixture records publications in memory. It never contacts MASC.
const workspaceRoot = '/office-roundtrip-fixture'
async function document(draft: ArtifactDraft, revision: number): Promise<ArtifactDocument> {
  const hash = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(draft.content))
  const sha256 = Array.from(new Uint8Array(hash), byte => byte.toString(16).padStart(2, '0')).join('')
  const artifact = { id: `artifact-${'d'.repeat(32)}`, revision, title: draft.title, summary: draft.summary,
    format: draft.format, author: 'fixture', created_at: new Date().toISOString(), task_id: null, goal_id: null,
    url: '/', body: { _blob: { sha256 } } }
  return { artifact, content: draft.content, revisions: [artifact] }
}
const charts = (['column', 'bar', 'line', 'pie'] as const).map(type => officeChartFigure({ type, title: `${type} 실적`,
  categories: ['서울', '부산', '제주'], series: [{ name: '실적', values: [0, null, 12.5] }] })).join('')
const initial = { title: '표와 차트 보고서', summary: '기관 양식 문서 변환 확인', format: 'html' as const,
  content: '<h1>사업 실적 보고서</h1><table><tr><th rowspan="2">담당</th><th colspan="2">실적</th></tr><tr><th>건수</th><th>금액</th></tr><tr><td>운영팀</td><td>3</td><td>25000</td></tr></table>' + charts }
let stored = await document(initial, 1)
const response = (value: unknown): Response => new Response(JSON.stringify(value), { headers: {
  'content-type': 'application/json', 'x-masc-workspace-read': 'matched-v1',
} })
window.fetch = async (input, init) => {
  const url = new URL(input instanceof Request ? input.url : String(input), location.href)
  const request = new Request(url, init)
  if (url.pathname === '/health') return response({ paths: { effective_base_path: workspaceRoot, effective_masc_root: `${workspaceRoot}/.masc` } })
  if (url.pathname === '/api/v1/published-artifacts' && request.method === 'POST') {
    const payload: unknown = JSON.parse(await request.text())
    if (payload === null || typeof payload !== 'object' || !('title' in payload) || typeof payload.title !== 'string'
      || !('summary' in payload) || typeof payload.summary !== 'string' || !('content' in payload) || typeof payload.content !== 'string'
      || !('format' in payload) || (payload.format !== 'html' && payload.format !== 'markdown')) throw new Error('Invalid fixture publication')
    stored = await document({ title: payload.title, summary: payload.summary, content: payload.content, format: payload.format }, stored.artifact.revision + 1)
    return response({ schema: 'masc.published_artifact.v1', artifact: stored.artifact, revision_url: '/' })
  }
  if (url.pathname === `/api/v1/published-artifacts/${stored.artifact.id}` && request.method === 'GET') return response(stored)
  throw new Error(`Fixture refused request: ${url.pathname}`)
}
setStoredToken('office-roundtrip-fixture')

function Fixture() {
  const [doc, setDoc] = useState(stored), [importing, setImporting] = useState(false)
  const retained = useRef<ArtifactDraftSnapshot | null>(null)
  const retention = {
    remember: (snapshot: ArtifactDraftSnapshot) => { retained.current = snapshot },
    release: () => {},
    forget: (identity: object) => { if (retained.current?.identity === identity) retained.current = null },
  }
  return html`<main>
    <h1>표·차트 문서 왕복 확인</h1>
    <p>격리된 확인 화면입니다. 게시 내용은 이 탭의 메모리에만 보관합니다.</p>
    <button onClick=${() => setImporting(true)}>파일 가져오기</button>
    ${importing ? html`<${ArtifactImport} workspaceRoot=${workspaceRoot} draftRetention=${retention} isCurrent=${() => true}
      onMutation=${() => {}} onSaved=${() => { setDoc(stored); setImporting(false) }} onCancel=${() => setImporting(false)} />` : null}
    <p role="status">현재 문서: ${doc.artifact.title} · v${doc.artifact.revision}</p>
    <${ArtifactWordExport} key=${doc.artifact.revision} doc=${doc} authRevision=${currentStoredTokenRevision()} isCurrent=${() => true} disabled=${false} />
    <iframe title="문서 미리보기" sandbox="allow-scripts" srcDoc=${artifactAppFrame(doc.content).document}></iframe>
  </main>`
}
render(html`<${Fixture} />`, window.document.getElementById('app')!)
