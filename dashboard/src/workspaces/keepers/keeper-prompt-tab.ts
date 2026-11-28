/**
 * Keeper → Prompt: what this keeper was told on its last assembled turn.
 *
 * - `GET /last-prompt` keeps the blocks in assembly order, the text they
 *   assembled into and the system prompt. The blocks are stable turn to turn,
 *   so the last assembly is also the preview of the next one.
 * - `GET /provider-input?turn_ref=` lists the parts of that same turn's
 *   provider request (system prompt, messages, tool schemas) without their
 *   text; a part's text is read when the operator opens it.
 * - Both are admin reads on the server, so a session without admin sees a
 *   notice and sends nothing.
 */

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { authSession, resourceCache, sessionEpoch, type Observed } from '../../core'
import { RefreshButton } from '../../components/primitives/refresh-button'
import { isAdminLockedForSession } from '../../routes/router'
import type { ProviderInputPart, ProviderInputSnapshot } from '../../api/dashboard-provider-input'
import { fetchKeeperLastPromptApi, fetchKeeperProviderInputApi, fetchKeeperProviderInputPartApi } from './keepers-api'
import { PROMPT_BLOCK_IDS, type PromptBlockId, type PromptCapture } from './prompt-capture-wire'

/** What each injection site carries (`Prompt_block_id`, `keeper_context_assembly.ml`). */
const BLOCK_NAMES: Readonly<Record<PromptBlockId, { readonly label: string; readonly what: string }>> = {
  keeper_instructions: { label: 'Keeper 지시문', what: '렌더된 system prompt' },
  dynamic_context: { label: '턴 맥락', what: '이어 받기 스냅샷, skill 경로, worktree, 최근 실패 기억 같은 나머지 맥락' },
  active_goals: { label: '진행 중 Goal', what: 'Goal 스냅샷과 지금 기준·측정값' },
  direct_input_source: { label: '직접 작업 출처', what: '받아들인 직접 작업의 출처. 권한을 주지 않아요' },
  completion_authority: { label: '완료 승인 기록', what: 'Task 승인·거절 사건과 그 연결 키' },
  goals_awaiting_proof: { label: '증명 기다리는 Goal', what: '검증자가 판정 중인(Verifying) Goal' },
  constitution_amendments: { label: '세계 조항 변경', what: 'System 을 렌더한 뒤 쓰이거나 거둬진 세계 조항' },
  temporal_summary: { label: '시간 요약', what: '공유 맥락의 시간 요약' },
  memory_os_recall: { label: 'Memory 회상', what: 'Memory OS 가 이 턴에 꺼낸 사실' },
  librarian_working_context: { label: '사서 작업 맥락', what: '작은 작업 맥락 자료 색인' },
  recalled_memory: { label: '불러온 기억', what: '회상 판정이 가져온 기억 본문' },
  recalled_memory_status: { label: '회상 판정', what: '판정 결과, 그 턴, 가져온 id' },
  operator_note: { label: '운영자 메모', what: '운영자가 이 Keeper 에게 남긴 메모' },
  skill_compositions: { label: 'Skill 조합', what: '이 턴의 도구에 실린 조합 Skill 이름' },
  arrived_stimuli: { label: '턴 중 도착', what: '턴이 시작된 뒤 큐에 들어온 항목' },
}

// One tone per block id, by declaration order, so a block keeps its color from turn to turn.
const BLOCK_TONES = ['var(--info-fg)', 'var(--ok-fg)', 'var(--brass-1)', 'var(--warn-fg)', 'var(--fg-2)'] as const

function blockTone(id: PromptBlockId): string {
  return BLOCK_TONES[PROMPT_BLOCK_IDS.indexOf(id) % BLOCK_TONES.length]!
}

type View = 'blocks' | 'assembled' | 'system' | 'provider'

const VIEWS: readonly (readonly [View, string])[] = [
  ['blocks', '블록'],
  ['assembled', '합쳐진 텍스트'],
  ['system', 'System prompt'],
  ['provider', 'Provider 요청'],
]

type PartText =
  | { readonly kind: 'loading' }
  | { readonly kind: 'text'; readonly text: string }
  | { readonly kind: 'failed'; readonly why: string }

const captureKey = (keeper: string) => `keeper:${keeper}:last-prompt`
const providerKey = (keeper: string, turnRef: string) => `keeper:${keeper}:provider-input:${turnRef}`
const turnRefOf = (capture: PromptCapture) => `${capture.trace_id}#${capture.absolute_turn}`

function loadCapture(keeper: string, reason: 'mount' | 'manual') {
  return resourceCache.fetch<PromptCapture>(
    captureKey(keeper),
    (signal) => fetchKeeperLastPromptApi(keeper, signal),
    { ttlMs: 30_000, topics: ['keeper-prompt'], reason },
  )
}

function loadProviderInput(keeper: string, turnRef: string) {
  return resourceCache.fetch<ProviderInputSnapshot>(
    providerKey(keeper, turnRef),
    (signal) => fetchKeeperProviderInputApi(keeper, turnRef, signal),
    { ttlMs: 30_000, topics: ['keeper-prompt'], reason: 'mount' },
  )
}

const preStyle = {
  margin: 0,
  padding: 'var(--sp-2)',
  background: 'var(--bg-0)',
  border: '1px solid var(--line-1)',
  borderRadius: 'var(--radius-sm)',
  fontSize: 'var(--fs-12)',
  lineHeight: 1.5,
  whiteSpace: 'pre-wrap',
  overflowWrap: 'anywhere',
  maxHeight: '60vh',
  overflowY: 'auto',
} as const
const noteStyle = { fontSize: 'var(--fs-12)', color: 'var(--fg-2)' } as const

function partLabel(part: ProviderInputPart): string {
  switch (part.kind) {
    case 'system_prompt':
      return 'System prompt'
    case 'message':
      return `message · ${part.role}`
    case 'tool_schema':
      return `tool · ${part.name}`
  }
}

function Composition({ capture }: { capture: PromptCapture }) {
  const total = capture.blocks.reduce((sum, b) => sum + b.bytes, 0)
  if (total === 0) return null
  return html`
    <div data-testid="keeper-prompt-composition" role="img" aria-label="블록별 바이트 비율"
      style=${{ display: 'flex', height: '0.75rem', borderRadius: 'var(--radius-sm)', overflow: 'hidden', border: '1px solid var(--line-1)' }}>
      ${capture.blocks.map((b, i) => html`
        <span key=${`${i}:${b.id}`} title=${`${BLOCK_NAMES[b.id].label} · ${b.bytes} bytes`}
          style=${{ width: `${(b.bytes / total) * 100}%`, background: blockTone(b.id), opacity: 0.75 }} />
      `)}
    </div>
  `
}

function Flow({ capture, provider }: { capture: PromptCapture; provider: ProviderInputSnapshot | null }) {
  const count = (kind: ProviderInputPart['kind']) => provider?.parts.filter(p => p.kind === kind).length ?? 0
  const box = (title: string, body: string) => html`
    <div class="kp-kv-box" style=${{ minWidth: '9rem', flex: '1 1 9rem' }}>
      <div style=${{ fontSize: 'var(--fs-12)', fontWeight: 600 }}>${title}</div>
      <div style=${noteStyle}>${body}</div>
    </div>
  `
  const arrow = html`<span aria-hidden="true" style=${{ alignSelf: 'center', color: 'var(--fg-3)' }}>→</span>`
  return html`
    <div data-testid="keeper-prompt-flow" style=${{ display: 'flex', gap: 'var(--sp-1)', flexWrap: 'wrap', alignItems: 'stretch' }}>
      ${box(`블록 ${capture.blocks.length}개`, `${capture.blocks.reduce((s, b) => s + b.bytes, 0).toLocaleString('en-US')} bytes`)}
      ${arrow}
      ${box('합쳐진 텍스트', capture.assembled === null ? '없음' : `${capture.assembled_bytes.toLocaleString('en-US')} bytes`)}
      ${arrow}
      ${box('Provider 요청', provider === null
        ? '이 턴의 요청 기록 없음'
        : `${provider.wire.provider}/${provider.wire.model} · system ${count('system_prompt')} · message ${count('message')} · tool ${count('tool_schema')} · ${provider.wire.bodyBytes.toLocaleString('en-US')} bytes`)}
    </div>
  `
}

function Blocks({ capture }: { capture: PromptCapture }) {
  const total = capture.blocks.reduce((sum, b) => sum + b.bytes, 0)
  if (capture.blocks.length === 0) return html`<div class="kp-empty">이 턴에 기록된 블록이 없어요.</div>`
  return html`
    <ol style=${{ margin: 0, paddingLeft: 0, listStyle: 'none', display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
      ${capture.blocks.map((b, i) => html`
        <li key=${`${i}:${b.id}`} data-testid="keeper-prompt-block">
          <details>
            <summary style=${{ cursor: 'pointer', display: 'flex', gap: 'var(--sp-1)', alignItems: 'baseline', flexWrap: 'wrap' }}>
              <span aria-hidden="true" style=${{ width: '0.6rem', height: '0.6rem', borderRadius: '50%', background: blockTone(b.id), display: 'inline-block' }} />
              <strong style=${{ fontSize: 'var(--fs-13)' }}>${i + 1}. ${BLOCK_NAMES[b.id].label}</strong>
              <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>${b.id}</span>
              <span style=${noteStyle}>${b.bytes.toLocaleString('en-US')} bytes${total > 0 ? ` · ${Math.round((b.bytes / total) * 100)}%` : ''}</span>
              <span style=${{ ...noteStyle, color: 'var(--fg-3)' }}>${BLOCK_NAMES[b.id].what}</span>
            </summary>
            ${b.text === '' ? html`<div class="kp-empty">비어 있어요.</div>` : html`<pre class="mono" style=${preStyle}>${b.text}</pre>`}
          </details>
        </li>
      `)}
    </ol>
  `
}

function ProviderParts({ keeper, turnRef, provider }: { keeper: string; turnRef: string; provider: ProviderInputSnapshot }) {
  const [texts, setTexts] = useState<ReadonlyMap<number, PartText>>(new Map())
  const put = (index: number, value: PartText) => setTexts(prev => new Map(prev).set(index, value))
  const open = async (part: ProviderInputPart) => {
    if (texts.has(part.index)) return
    put(part.index, { kind: 'loading' })
    const res = await fetchKeeperProviderInputPartApi(keeper, turnRef, part)
    put(part.index, res.ok ? { kind: 'text', text: res.value } : { kind: 'failed', why: res.error.message })
  }
  return html`
    <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
      <div style=${noteStyle}>${provider.wire.provider}/${provider.wire.model} · ${provider.wire.httpCodec} · ${provider.runtimeProfile}</div>
      ${provider.parts.map(part => {
        const state = texts.get(part.index)
        return html`
          <details key=${part.index} data-testid="keeper-prompt-part" onToggle=${(e: Event) => { if ((e.currentTarget as HTMLDetailsElement).open) void open(part) }}>
            <summary style=${{ cursor: 'pointer', display: 'flex', gap: 'var(--sp-1)', alignItems: 'baseline' }}>
              <span class="mono" style=${{ fontSize: 'var(--fs-12)' }}>#${part.index} ${partLabel(part)}</span>
              <span style=${noteStyle}>${part.bytes.toLocaleString('en-US')} bytes</span>
            </summary>
            ${state?.kind === 'loading' && html`<div class="kp-empty">불러오는 중…</div>`}
            ${state?.kind === 'failed' && html`<div class="ap-error" role="alert">읽지 못했어요: ${state.why}</div>`}
            ${state?.kind === 'text' && html`<pre class="mono" style=${preStyle}>${state.text}</pre>`}
          </details>
        `
      })}
    </div>
  `
}

function ProviderView({ keeper, turnRef, obs }: { keeper: string; turnRef: string; obs: Observed<ProviderInputSnapshot> }) {
  switch (obs.kind) {
    case 'value':
      return html`<${ProviderParts} key=${turnRef} keeper=${keeper} turnRef=${turnRef} provider=${obs.data} />`
    case 'loading':
      return html`<div class="kp-empty">불러오는 중…</div>`
    case 'absent':
    case 'unreported':
      return html`<div class="kp-empty" data-testid="keeper-prompt-provider-absent">이 턴의 Provider 요청 기록이 없어요${obs.reason === undefined ? '.' : `: ${obs.reason}`}</div>`
    case 'failed':
      return html`<div class="ap-error" role="alert">이 턴의 Provider 요청을 읽지 못했어요: ${obs.error.message}</div>`
  }
}

function KeeperPromptView({ keeperName }: { keeperName: string }) {
  const epoch = sessionEpoch.value
  const obs = resourceCache.observe<PromptCapture>(captureKey(keeperName)).value
  const capture = obs.kind === 'value' ? obs.data : null
  const turnRef = capture === null ? null : turnRefOf(capture)
  const providerObs = resourceCache.observe<ProviderInputSnapshot>(providerKey(keeperName, turnRef ?? '')).value
  const provider = turnRef !== null && providerObs.kind === 'value' ? providerObs.data : null
  const [view, setView] = useState<View>('blocks')

  useEffect(() => {
    void loadCapture(keeperName, 'mount')
  }, [keeperName, epoch])
  useEffect(() => {
    if (turnRef !== null) void loadProviderInput(keeperName, turnRef)
  }, [keeperName, turnRef, epoch])

  return html`
    <section class="kp-scroll-pane" data-keeper-tab="prompt" aria-label="Keeper 프롬프트">
      <div class="kp-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
        <div class="kp-card-head">
          <h3>마지막으로 조립한 프롬프트 · ${keeperName}</h3>
          <${RefreshButton} onRefresh=${() => loadCapture(keeperName, 'manual')} />
        </div>
        ${obs.kind === 'loading' && html`<div class="kp-empty">불러오는 중…</div>`}
        ${obs.kind === 'absent' && html`<div class="kp-empty" data-testid="keeper-prompt-not-captured">아직 조립한 턴이 없어요${obs.reason === undefined ? '.' : `: ${obs.reason}`}</div>`}
        ${obs.kind === 'unreported' && html`<div class="kp-empty">서버가 이 Keeper 의 프롬프트를 알려 주지 않았어요${obs.reason === undefined ? '.' : `: ${obs.reason}`}</div>`}
        ${obs.kind === 'failed' && html`<div class="ap-error" role="alert">프롬프트를 읽지 못했어요: ${obs.error.message}</div>`}
        ${capture !== null && html`
          <div style=${noteStyle}>
            Turn #${capture.absolute_turn} · ${new Date(capture.captured_at * 1000).toLocaleString('ko-KR')} · <span class="mono">${capture.trace_id}</span>
          </div>
          <div style=${noteStyle}>블록은 턴마다 거의 같아서, 마지막 조립이 다음 턴의 미리 보기이기도 해요.</div>
          <${Flow} capture=${capture} provider=${provider} />
          <${Composition} capture=${capture} />
          <div class="ap-viewseg" role="group" aria-label="프롬프트 보기 선택" style=${{ alignSelf: 'flex-start', flexWrap: 'wrap' }}>
            ${VIEWS.map(([id, label]) => html`
              <button key=${id} type="button" data-view=${id} aria-pressed=${view === id} class=${`ap-viewbtn ${view === id ? 'on' : ''}`} onClick=${() => setView(id)}>${label}</button>
            `)}
          </div>
          ${view === 'blocks' && html`<${Blocks} capture=${capture} />`}
          ${view === 'assembled' && (capture.assembled === null
            ? html`<div class="kp-empty">이 턴은 합쳐진 텍스트를 남기지 않았어요.</div>`
            : html`<pre class="mono" data-testid="keeper-prompt-assembled" style=${preStyle}>${capture.assembled}</pre>`)}
          ${view === 'system' && (capture.system_prompt === null
            ? html`<div class="kp-empty">이 턴은 system prompt 를 남기지 않았어요.</div>`
            : html`<pre class="mono" style=${preStyle}>${capture.system_prompt}</pre>`)}
          ${view === 'provider' && turnRef !== null && html`<${ProviderView} keeper=${keeperName} turnRef=${turnRef} obs=${providerObs} />`}
        `}
      </div>
    </section>
  `
}

export function KeeperPromptTab({ keeperName }: { readonly keeperName: string }) {
  if (isAdminLockedForSession('admin', authSession.value)) return html`
    <section class="kp-scroll-pane" data-keeper-tab="prompt" aria-label="Keeper 프롬프트">
      <div class="kp-card" data-testid="keeper-prompt-admin-locked" role="status">
        <h3>Prompt · ${keeperName}</h3>
        <p>Keeper 가 받은 프롬프트와 Provider 요청은 관리자 세션에서 볼 수 있어요.</p>
      </div>
    </section>
  `
  return html`<${KeeperPromptView} key=${`${sessionEpoch.value}:${keeperName}`} keeperName=${keeperName} />`
}
