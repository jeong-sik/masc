/**
 * Runtime L1 Tab 5: Lane-Addons & Browser
 *
 * - 2-pane MasterDetail inspector:
 *   Left = /api/v1/lane-addons live/retained instances + package catalog/preview + attach/detach
 *          + invoke actions + live host requests / asks.
 *   Right = Browser Lane Clients & On-Demand Open Tabs (/api/v1/dashboard/browser-lane/clients
 *           & POST /api/v1/dashboard/browser-lane/read), gracefully handling HTTP 503 unattached
 *           state per #36.
 */

import { html } from 'htm/preact'
import { useEffect, useId, useState } from 'preact/hooks'
import {
  apiGet,
  apiMutate,
  apiRequest,
  resourceCache,
} from '../../core'
import { MasterDetail, VirtualList } from '../../components/primitives'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import type {
  BrowserClientRow,
  BrowserClientsPayload,
  BrowserTabRow,
  LaneAddonAskRow,
  LaneAddonAsksResponse,
  LaneAddonInstanceRow,
  LaneAddonsPayload,
  WorkspaceViewProps,
} from './types'

interface PackageCatalogPayload {
  readonly directory: string
  readonly parent: string | null
  readonly entries: readonly (
    | { readonly kind: 'folder'; readonly path: string }
    | { readonly kind: 'issue'; readonly path: string; readonly message: string }
    | { readonly kind: 'package'; readonly manifest_path: string; readonly title: string; readonly revision: string; readonly description: string | null }
  )[]
}

interface PackagePreviewPayload {
  readonly manifest_path: string
  readonly package: { readonly title: string; readonly revision: string }
  readonly execution: { readonly kind: string; readonly image_name?: string }
}

type BrowserLaneState =
  | { readonly kind: 'loading' }
  | { readonly kind: 'unattached_503'; readonly reason: string }
  | { readonly kind: 'failed'; readonly message: string }
  | { readonly kind: 'ready'; readonly data: BrowserClientsPayload }

export function AddonsTab(props: WorkspaceViewProps) {
  const addonsObs = resourceCache.observe<LaneAddonsPayload>('runtime:lane-addons').value
  const asksObs = resourceCache.observe<LaneAddonAsksResponse>('runtime:lane-addons-asks').value
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [catalog, setCatalog] = useState<PackageCatalogPayload | null>(null)
  const [preview, setPreview] = useState<PackagePreviewPayload | null>(null)
  const [attachRunId, setAttachRunId] = useState('default')
  const [actionJson, setActionJson] = useState('{}')
  const askPromptId = useId()
  const [askAnswersByKey, setAskAnswersByKey] = useState<Readonly<Record<string, string>>>({})
  const [banner, setBanner] = useState<{ kind: 'ok' | 'err'; text: string } | null>(null)

  const [browserState, setBrowserState] = useState<BrowserLaneState>({ kind: 'loading' })
  const [tabsByClient, setTabsByClient] = useState<Readonly<Record<string, readonly BrowserTabRow[]>>>({})
  const [readingClient, setReadingClient] = useState<string | null>(null)

  const loadAddons = (reason: 'mount' | 'manual' = 'mount') => {
    void resourceCache.fetch<LaneAddonsPayload>(
      'runtime:lane-addons',
      (signal) => apiGet<LaneAddonsPayload>('/api/v1/lane-addons', { signal }),
      { ttlMs: 15_000, topics: ['lane_addon'], reason },
    )
    void resourceCache.fetch<LaneAddonAsksResponse>(
      'runtime:lane-addons-asks',
      (signal) => apiGet<LaneAddonAsksResponse>('/api/v1/lane-addons/asks', { signal }),
      { ttlMs: 15_000, topics: ['lane_addon'], reason },
    )
  }

  const loadBrowserLane = async () => {
    setBrowserState({ kind: 'loading' })
    const res = await apiRequest<BrowserClientsPayload>({
      method: 'GET',
      path: '/api/v1/dashboard/browser-lane/clients',
      envelope: 'ok_data',
    })
    if (!res.ok) {
      if (res.error.status === 503) {
        setBrowserState({
          kind: 'unattached_503',
          reason: res.error.message || '브라우저 레인 애드온이 아직 연결되지 않았습니다.',
        })
      } else {
        setBrowserState({ kind: 'failed', message: res.error.message })
      }
      return
    }
    setBrowserState({ kind: 'ready', data: res.value })
  }

  const loadCatalog = async (directory?: string) => {
    const query = directory ? `?directory=${encodeURIComponent(directory)}` : ''
    const res = await apiGet<PackageCatalogPayload>(`/api/v1/lane-addons/package-catalog${query}`)
    if (res.ok) setCatalog(res.value)
    else setBanner({ kind: 'err', text: `패키지 카탈로그 조회 실패: ${res.error.message}` })
  }

  useEffect(() => {
    loadAddons('mount')
    void loadBrowserLane()
  }, [])

  const instances = addonsObs.kind === 'value' ? addonsObs.data.instances : []
  const selectedInstance = instances.find((i) => i.instance_id === selectedId) ?? instances[0] ?? null

  const handlePreviewManifest = async (manifestPath: string) => {
    const res = await apiGet<PackagePreviewPayload>(
      `/api/v1/lane-addons/package-preview?manifest_path=${encodeURIComponent(manifestPath)}`,
    )
    if (res.ok) setPreview(res.value)
    else setBanner({ kind: 'err', text: `미리보기 실패: ${res.error.message}` })
  }

  const handleAttach = async (manifestPath: string) => {
    const res = await apiMutate<unknown>('POST', '/api/v1/lane-addons/attach', {
      manifest_path: manifestPath,
      run_id: attachRunId.trim() || 'default',
      binding: {},
    })
    if (!res.ok) {
      setBanner({ kind: 'err', text: `애드온 Attach 실패: ${res.error.message}` })
      return
    }
    setBanner({ kind: 'ok', text: `애드온 연결됨 (${manifestPath}).` })
    setPreview(null)
    loadAddons('manual')
    void loadBrowserLane()
  }

  const handleDetach = async (instanceId: string) => {
    const res = await apiMutate<unknown>('POST', '/api/v1/lane-addons/detach', { instance_id: instanceId })
    if (!res.ok) {
      setBanner({ kind: 'err', text: `Detach 실패: ${res.error.message}` })
      return
    }
    setBanner({ kind: 'ok', text: `${instanceId} 연결 해제 요청 완료.` })
    loadAddons('manual')
  }

  const handleObserve = async (instanceId: string) => {
    const res = await apiMutate<unknown>('POST', '/api/v1/lane-addons/observe', { instance_id: instanceId })
    if (!res.ok) {
      setBanner({ kind: 'err', text: `관측 트리거 실패: ${res.error.message}` })
      return
    }
    loadAddons('manual')
  }

  const handleInvokeAction = async (inst: LaneAddonInstanceRow) => {
    let parsedAction: Record<string, unknown>
    try {
      const val = JSON.parse(actionJson)
      if (!val || typeof val !== 'object' || Array.isArray(val)) throw new Error('JSON 객체가 필요합니다.')
      parsedAction = val as Record<string, unknown>
    } catch (err) {
      setBanner({ kind: 'err', text: `액션 JSON 오류: ${err instanceof Error ? err.message : String(err)}` })
      return
    }
    const requestId = `req-${Date.now()}`
    const res = await apiMutate<unknown>('POST', '/api/v1/lane-addons/actions', {
      instance_id: inst.instance_id,
      expected_incarnation: inst.incarnation,
      request_id: requestId,
      action: parsedAction,
    })
    if (!res.ok) {
      setBanner({ kind: 'err', text: `액션 호출 실패: ${res.error.message}` })
      return
    }
    setBanner({ kind: 'ok', text: `액션 요청 접수됨 (${requestId}).` })
    props.onInspect({
      title: `Addon Action Receipt · ${inst.title}`,
      subtitle: requestId,
      kind: 'addon_action_receipt',
      data: res.value,
      render: () => html`
        <pre class="mono" style=${{ margin: 0, fontSize: 'var(--fs-11)', overflowX: 'auto', whiteSpace: 'pre-wrap' }}>
          ${JSON.stringify(res.value, null, 2)}
        </pre>
      `,
    })
  }

  // Exact OCaml contract (lib/server/server_routes_http_routes_lane_addons.ml:692-713,808):
  // POST /api/v1/lane-addons/ask-answer with { declaration_id, ask_id, answers }
  const handleAnswerAddonAsk = async (ask: LaneAddonAskRow) => {
    const submissions = ask.questions.map((q, idx) => {
      const qid = q.id ?? q.question_id ?? `q-${idx}`
      const key = `${ask.ask_id}:${qid}`
      const text = (askAnswersByKey[key] ?? '').trim()
      return {
        question_id: qid,
        response: text.length > 0
          ? { kind: 'wrote' as const, text }
          : { kind: 'skipped' as const },
      }
    })
    if (submissions.length === 0) {
      setBanner({ kind: 'err', text: '응답할 질문 항목이 없습니다.' })
      return
    }
    const res = await apiMutate<unknown>('POST', '/api/v1/lane-addons/ask-answer', {
      declaration_id: ask.declaration_id,
      ask_id: ask.ask_id,
      answers: submissions,
    })
    if (!res.ok) {
      setBanner({ kind: 'err', text: `애드온 질문 응답 실패: ${res.error.message}` })
      return
    }
    setBanner({ kind: 'ok', text: `애드온 질문 ${ask.ask_id} 응답이 기록되었습니다.` })
    loadAddons('manual')
  }

  const handleReadOpenTabs = async (client: BrowserClientRow) => {
    setReadingClient(client.clientId)
    const res = await apiMutate<{
      readonly ok?: boolean
      readonly data?: { readonly tabs?: readonly BrowserTabRow[] }
      readonly tabs?: readonly BrowserTabRow[]
    }>('POST', '/api/v1/dashboard/browser-lane/read', {
      lane: 'live',
      clientId: client.clientId,
    })
    setReadingClient(null)
    if (!res.ok) {
      setBanner({ kind: 'err', text: `탭 읽기 실패 (${client.clientId}): ${res.error.message}` })
      return
    }
    const tabs = res.value.data?.tabs ?? res.value.tabs ?? []
    setTabsByClient((prev) => ({ ...prev, [client.clientId]: tabs }))
    props.onInspect({
      title: `Browser Tabs · ${client.clientId}`,
      subtitle: `${tabs.length}개 열린 탭`,
      kind: 'browser_tabs',
      data: tabs,
      render: () => html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
          ${tabs.length === 0
            ? html`<div class="dtable-absent">열린 탭 없음</div>`
            : tabs.map((t) => html`
                <div key=${t.id} class="wka-card" style=${{ fontSize: 'var(--fs-12)' }}>
                  <div style=${{ fontWeight: 600 }}>${t.active ? '● ' : ''}${t.title || '(제목 없음)'}</div>
                  <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--info-fg)', wordBreak: 'break-all' }}>${t.url}</div>
                </div>
              `)}
        </div>
      `,
    })
  }

  const leftPane = html`
    <div style=${{ padding: 'var(--sp-3)', display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', minWidth: 0 }}>
      <div class="wka-h">
        <h3>Lane-Addons 인스턴스 (${instances.length})</h3>
        <div style=${{ display: 'flex', gap: 'var(--sp-1)' }}>
          <button type="button" class="btn-ghost" onClick=${() => void loadCatalog()}>패키지 탐색</button>
          <button type="button" class="btn-ghost" onClick=${() => loadAddons('manual')}>새로고침</button>
        </div>
      </div>

      ${instances.length === 0
        ? html`<div class="dtable-absent">${addonsObs.kind === 'loading' ? '불러오는 중…' : '연결된 Lane-Addon 인스턴스가 없습니다.'}</div>`
        : html`
            <${VirtualList}
              items=${instances}
              estimateSize=${64}
              height=${Math.min(260, Math.max(120, instances.length * 68))}
              ariaLabel="Lane-Addon 인스턴스 목록"
              renderItem=${(inst: LaneAddonInstanceRow) => {
                const isSel = selectedInstance?.instance_id === inst.instance_id
                return html`
                  <button
                    type="button"
                    onClick=${() => setSelectedId(inst.instance_id)}
                    style=${{
                      width: '100%',
                      textAlign: 'left',
                      padding: 'var(--sp-2)',
                      background: isSel ? 'var(--bg-4)' : 'var(--bg-2)',
                      border: '1px solid var(--line-1)',
                      borderRadius: 'var(--radius-sm)',
                      cursor: 'pointer',
                      display: 'flex',
                      justifyContent: 'space-between',
                      alignItems: 'center',
                      gap: 'var(--sp-2)',
                    }}
                  >
                    <div style=${{ minWidth: 0 }}>
                      <div style=${{ fontWeight: 600, fontSize: 'var(--fs-13)' }}>${inst.title}</div>
                      <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                        ${inst.instance_id} · seq ${inst.observation_seq} · ${inst.rows_count}행
                      </div>
                    </div>
                    <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: inst.runtime_presence === 'live' ? 'var(--ok-fg)' : 'var(--fg-3)' }}>
                      ${inst.runtime_presence ?? 'retained'} / ${inst.phase.kind}
                    </span>
                  </button>
                `
              }}
            />
          `}

      ${selectedInstance && html`
        <div class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', background: 'var(--bg-2)' }}>
          <div class="wka-h">
            <h3>${selectedInstance.title} 제어</h3>
            <div style=${{ display: 'flex', gap: 'var(--sp-1)' }}>
              <button type="button" class="btn-ghost" onClick=${() => void handleObserve(selectedInstance.instance_id)}>관측</button>
              <button type="button" class="btn-ghost" style=${{ color: 'var(--err-fg)' }} onClick=${() => void handleDetach(selectedInstance.instance_id)}>Detach</button>
            </div>
          </div>
          <label style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
            <span>액션 호출 (JSON)</span>
            <textarea
              rows=${3}
              class="mono"
              value=${actionJson}
              onInput=${(e: Event) => setActionJson((e.target as HTMLTextAreaElement).value)}
              style=${{ padding: 'var(--sp-2)', fontSize: 'var(--fs-11)', background: 'var(--bg-0)', border: '1px solid var(--line-1)', borderRadius: 'var(--radius-sm)' }}
            />
          </label>
          <button type="button" class="btn-primary" style=${{ alignSelf: 'flex-start' }} onClick=${() => void handleInvokeAction(selectedInstance)}>
            액션 실행
          </button>

          ${(selectedInstance.host_requests?.waiting?.length ?? 0) > 0 && html`
            <div style=${{ borderTop: '1px solid var(--line-1)', paddingTop: 'var(--sp-2)' }}>
              <div style=${{ fontSize: 'var(--fs-12)', fontWeight: 600, color: 'var(--warn-fg)', marginBottom: 'var(--sp-1)' }}>
                대기 중인 호스트 요청 (${selectedInstance.host_requests!.waiting!.length})
              </div>
              ${selectedInstance.host_requests!.waiting!.map((w) => html`
                <div key=${w.request_id} class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-2)' }}>
                  ${w.request_id} · ${String(w.reason.reason ?? 'waiting')}
                </div>
              `)}
            </div>
          `}
        </div>
      `}

      ${asksObs.kind === 'value' && (asksObs.data.asks?.length ?? 0) > 0 && html`
        <div class="wka-card" data-testid="lane-addon-asks-panel" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', borderColor: 'var(--warn-border)' }}>
          <div class="wka-h">
            <h3>열린 Lane-Addon 질문 (${asksObs.data.asks!.length})</h3>
          </div>
          ${asksObs.data.asks!.map((ask, askIndex) => html`
            <div key=${ask.ask_id} style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', padding: 'var(--sp-2)', background: 'var(--bg-2)', borderRadius: 'var(--radius-sm)' }}>
              <div style=${{ fontWeight: 600, fontSize: 'var(--fs-12)' }}>${ask.title}</div>
              <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                declaration=${ask.declaration_id} · ask=${ask.ask_id}
              </div>
              ${ask.questions.map((q, qIdx) => {
                const qid = q.id ?? q.question_id ?? `q-${qIdx}`
                const key = `${ask.ask_id}:${qid}`
                const promptId = `${askPromptId}-${askIndex}-${qIdx}`
                return html`
                  <div key=${key} style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', fontSize: 'var(--fs-12)' }}>
                    <div id=${promptId}>
                      <${MarkdownContent} text=${q.prompt ?? q.text ?? q.label ?? qid} />
                    </div>
                    <input
                      type="text"
                      aria-labelledby=${promptId}
                      placeholder="응답 입력 (비우면 skipped)"
                      value=${askAnswersByKey[key] ?? ''}
                      onInput=${(e: Event) => setAskAnswersByKey((prev) => ({ ...prev, [key]: (e.target as HTMLInputElement).value }))}
                      style=${{ padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                    />
                  </div>
                `
              })}
              <button
                type="button"
                class="btn-primary"
                style=${{ alignSelf: 'flex-start' }}
                onClick=${() => void handleAnswerAddonAsk(ask)}
              >
                질문 응답 제출
              </button>
            </div>
          `)}
        </div>
      `}

      ${catalog && html`
        <div class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
          <div class="wka-h">
            <h3>패키지 카탈로그 (${catalog.directory})</h3>
            ${catalog.parent && html`
              <button type="button" class="btn-ghost" onClick=${() => void loadCatalog(catalog.parent!)}>↑ 상위</button>
            `}
          </div>
          <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
            ${catalog.entries.map((entry, idx) => {
              if (entry.kind === 'folder') {
                return html`
                  <button key=${`f-${idx}`} type="button" class="btn-ghost" style=${{ justifyContent: 'flex-start' }} onClick=${() => void loadCatalog(entry.path)}>
                    📁 ${entry.path}
                  </button>
                `
              }
              if (entry.kind === 'issue') {
                return html`<div key=${`i-${idx}`} style=${{ fontSize: 'var(--fs-11)', color: 'var(--err-fg)' }}>⚠ ${entry.path}: ${entry.message}</div>`
              }
              return html`
                <div key=${entry.manifest_path} style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 'var(--sp-2)', padding: 'var(--sp-1) var(--sp-2)', background: 'var(--bg-2)', borderRadius: 'var(--radius-sm)' }}>
                  <span style=${{ fontSize: 'var(--fs-12)' }}>${entry.title}</span>
                  <button type="button" class="btn-ghost" style=${{ padding: 'var(--sp-0) var(--sp-1)', fontSize: 'var(--fs-11)' }} onClick=${() => void handlePreviewManifest(entry.manifest_path)}>
                    미리보기
                  </button>
                </div>
              `
            })}
          </div>
          ${preview && html`
            <div style=${{ borderTop: '1px solid var(--line-1)', paddingTop: 'var(--sp-2)', display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
              <div style=${{ fontSize: 'var(--fs-12)', fontWeight: 600 }}>${preview.package.title} (${preview.execution.kind})</div>
              <div style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
                <input
                  type="text"
                  value=${attachRunId}
                  onInput=${(e: Event) => setAttachRunId((e.target as HTMLInputElement).value)}
                  placeholder="run_id"
                  style=${{ flex: 1, minWidth: 0, padding: 'var(--sp-1) var(--sp-2)', background: 'var(--input-bg)', border: '1px solid var(--input-border)', borderRadius: 'var(--radius-sm)' }}
                />
                <button type="button" class="btn-primary" onClick=${() => void handleAttach(preview.manifest_path)}>Attach</button>
              </div>
            </div>
          `}
        </div>
      `}
    </div>
  `

  const rightPane = html`
    <div style=${{ padding: 'var(--sp-3)', display: 'flex', flexDirection: 'column', gap: 'var(--sp-3)', minWidth: 0 }}>
      <div class="wka-h">
        <h3>Browser Lane 클라이언트 & 온디맨드 탭</h3>
        <button type="button" class="btn-ghost" onClick=${() => void loadBrowserLane()}>새로고침</button>
      </div>

      ${browserState.kind === 'loading' && html`<div class="dtable-absent">Browser Lane 상태 확인 중…</div>`}

      ${browserState.kind === 'unattached_503' && html`
        <div
          class="wka-card"
          data-testid="browser-lane-503"
          role="status"
          style=${{ borderColor: 'var(--warn-border)', background: 'var(--warn-soft)', display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}
        >
          <div style=${{ fontWeight: 600, color: 'var(--warn-fg)' }}>
            ⚠ Browser Lane 미연결 (HTTP 503)
          </div>
          <div style=${{ fontSize: 'var(--fs-12)', color: 'var(--fg-2)' }}>
            ${browserState.reason}
          </div>
          <div style=${{ display: 'flex', gap: 'var(--sp-2)' }}>
            <button type="button" class="btn-ghost" onClick=${() => void loadCatalog()}>왼쪽 카탈로그에서 애드온 Attach</button>
            <button type="button" class="btn-ghost" onClick=${() => void loadBrowserLane()}>다시 확인</button>
          </div>
        </div>
      `}

      ${browserState.kind === 'failed' && html`
        <div class="ap-error" role="alert">Browser Lane 조회 실패: ${browserState.message}</div>
      `}

      ${browserState.kind === 'ready' && html`
        <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)' }}>
          <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
            클라이언트 ${browserState.data.clients.length}개 · 인벤토리 ${browserState.data.inventoryComplete ? '완전' : '불완전'}
          </div>

          ${browserState.data.inventoryIssues.length > 0 && html`
            <div class="ap-error sev-warn">
              ${browserState.data.inventoryIssues.map((iss, i) => html`
                <div key=${i} class="mono" style=${{ fontSize: 'var(--fs-11)' }}>
                  [${iss.kind}] ${iss.message ?? iss.instanceId ?? ''}
                </div>
              `)}
            </div>
          `}

          ${browserState.data.clients.length === 0
            ? html`<div class="dtable-absent">연결된 브라우저 클라이언트가 없습니다.</div>`
            : browserState.data.clients.map((client) => {
                const tabs = tabsByClient[client.clientId]
                return html`
                  <article key=${client.clientId} class="wka-card" style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-2)', background: 'var(--bg-2)' }}>
                    <div style=${{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', gap: 'var(--sp-2)', flexWrap: 'wrap' }}>
                      <div>
                        <div style=${{ fontWeight: 600, fontSize: 'var(--fs-13)' }}>${client.browser} (${client.version})</div>
                        <div class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
                          ${client.clientId} · ${client.transport} ${client.space ? `· space:${client.space.name}` : ''}
                        </div>
                      </div>
                      <button
                        type="button"
                        class="btn-primary"
                        disabled=${readingClient === client.clientId}
                        onClick=${() => void handleReadOpenTabs(client)}
                      >
                        ${readingClient === client.clientId ? '읽는 중…' : 'Open Tabs 읽기'}
                      </button>
                    </div>
                    ${tabs && html`
                      <div style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)', borderTop: '1px solid var(--line-1)', paddingTop: 'var(--sp-1)' }}>
                        ${tabs.length === 0
                          ? html`<span class="dtable-absent" style=${{ fontSize: 'var(--fs-11)' }}>열린 탭 없음</span>`
                          : tabs.slice(0, 8).map((t) => html`
                              <div key=${t.id} style=${{ fontSize: 'var(--fs-11)', display: 'flex', gap: 'var(--sp-1)', minWidth: 0 }}>
                                <span style=${{ color: t.active ? 'var(--ok-fg)' : 'var(--fg-3)' }}>${t.active ? '●' : '○'}</span>
                                <span style=${{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>${t.title || t.url}</span>
                              </div>
                            `)}
                      </div>
                    `}
                  </article>
                `
              })}
        </div>
      `}
    </div>
  `

  return html`
    <div class="ov" data-testid="runtime-addons-tab">
      <header class="ov-head">
        <div>
          <span class="ov-eyebrow">5 RUNTIME · LANE-ADDONS & BROWSER</span>
          <h1>Lane-Addons 인스턴스 & Browser Lane 클라이언트</h1>
        </div>
      </header>

      ${banner && html`
        <div
          role="status"
          class=${banner.kind === 'err' ? 'ap-error' : 'wka-card'}
          style=${banner.kind === 'ok' ? { borderColor: 'var(--ok-border)', background: 'var(--ok-soft)', color: 'var(--ok-fg)' } : undefined}
        >
          ${banner.text}
        </div>
      `}

      <${MasterDetail}
        masterLabel="Lane-Addons 인스턴스"
        detailLabel="Browser Lane 클라이언트"
        master=${leftPane}
        detail=${rightPane}
      />
    </div>
  `
}
