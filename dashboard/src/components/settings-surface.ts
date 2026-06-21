// MASC Dashboard — Settings surface (keeper-v2 port)
// Read surfaces (MCP exposed-tools list, system-log tail, runtime defaults /
// model routing) are wired to live backend data. VerifyBtn performs a real
// read-only probe for MCP/Gate URLs (reachability) and the worktree basepath
// (existence) via /api/v1/dashboard/verify-resource (RFC-0273 §3.4). DB and
// linked-repo verification have no in-tree probe yet and render an honest
// "수동 확인" placeholder (DeferredVerifyBtn) rather than a fabricated "✓".
// Remaining write surfaces (Save changes, expose/unexpose persistence) are
// still local-state stubs.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { navigate } from '../router'
import { fetchDashboardTools, fetchLogs, fetchRuntimeDefaults, verifyResource } from '../api/dashboard.js'
import type {
  DashboardToolInventoryItem,
  LogEntry,
  RuntimeDefaultsResponse,
  VerifyResourceKind,
} from '../api/dashboard.js'
import type { ComponentChildren } from 'preact'

type SectionId =
  | 'account'
  | 'mcp'
  | 'runtime'
  | 'runtimes'
  | 'routing'
  | 'prompts'
  | 'policy'
  | 'lifecycle'
  | 'sandbox'
  | 'ide'
  | 'gate'
  | 'paths'
  | 'logs'
  | 'notify'
  | 'display'

type VerifyState = 'idle' | 'checking' | 'ok' | 'fail'
type LogFilter = 'all' | 'tool' | 'success' | 'failure'

const SET_SECTIONS: [SectionId, string, string][] = [
  ['account', 'Account', '계정'],
  ['mcp', 'MCP', 'MCP 서버'],
  ['runtime', 'Runtime', '런타임 기본값'],
  ['runtimes', 'Runtimes', '런타임 관리'],
  ['routing', 'Routing', '모델 라우팅'],
  ['prompts', 'Prompts', '기본 프롬프트'],
  ['policy', 'Policy', '승인 정책'],
  ['lifecycle', 'Lifecycle', 'keeper 수명'],
  ['sandbox', 'Sandbox', '샌드박스'],
  ['ide', 'IDE', 'IDE · 편집기'],
  ['gate', 'Gate', '커넥터 게이트'],
  ['paths', 'Paths', '경로 · Basepath'],
  ['logs', 'Logs', '관측 · 시스템 로그'],
  ['notify', 'Notify', '알림'],
  ['display', 'Display', '표시'],
]

const SET_GROUPS: [string, SectionId[]][] = [
  // KO group labels per keeper-v2 settings.jsx SET_GROUPS — matches the
  // Korean section names below (avoids EN-header / KO-item bilingual mismatch).
  ['계정', ['account']],
  ['Keeper 운영', ['runtime', 'routing', 'prompts', 'lifecycle', 'policy']],
  ['인프라 · 실행', ['runtimes', 'sandbox', 'paths']],
  ['연결 · 통합', ['mcp', 'gate', 'ide']],
  ['관측 · 표시', ['logs', 'notify', 'display']],
]

// Tools exposed over the public MCP server, derived from the live capability
// registry (`/api/v1/dashboard/tools`). The "public_mcp" surface is the
// registry's own exposure signal — see lib/tool_misc_introspection.ml
// (Tool_catalog.is_public_mcp). Unknown/empty inventory yields an empty list
// (no fabricated tool names).
const MCP_PUBLIC_SURFACE = 'public_mcp'
const SETTINGS_LOG_LIMIT = 50
const SETTINGS_LOG_POLL_MS = 3000

export function mcpExposedToolNames(items: readonly DashboardToolInventoryItem[]): string[] {
  return items
    .filter(item => item.surfaces.includes(MCP_PUBLIC_SURFACE))
    .map(item => item.name)
    .sort((a, b) => a.localeCompare(b))
}

const APPROVAL_ACTIONS: [string, string, string][] = [
  ['git push / merge', 'always', '원격 브랜치에 쓰기'],
  ['배포 (infra/deploy)', 'always', 'deploy 트리거'],
  ['외부 호출 (Slack·Discord 발신)', 'risky', '외부로 메시지 전송'],
  ['파일 쓰기 (worktree)', 'auto', 'keeper 워크트리 내 편집'],
  ['읽기 전용 도구', 'auto', 'query·trace·blame 등'],
]

// System-log row: [time, level, identity, message, status]. Derived from live
// ring entries (`/api/v1/dashboard/logs`) — the same source the Logs surface
// polls. Status is derived from the entry level only (error→fail, warn→warn,
// else→ok); the in-progress "run" state is not knowable from a settled ring
// entry, so it is never fabricated.
type SysLogRow = [string, string, string, string, string]

const SETTINGS_LOG_LEVEL_FAIL = 'error'
const SETTINGS_LOG_LEVEL_WARN = 'warn'

export function logRowStatus(level: string): 'ok' | 'warn' | 'fail' {
  const normalized = level.toLowerCase()
  if (normalized === SETTINGS_LOG_LEVEL_FAIL) return 'fail'
  if (normalized === SETTINGS_LOG_LEVEL_WARN) return 'warn'
  return 'ok'
}

function logRowClock(ts: string): string {
  const match = ts.match(/T(\d{2}:\d{2}:\d{2})/)
  if (match?.[1]) return match[1]
  const date = new Date(ts)
  if (!Number.isNaN(date.getTime())) {
    return date.toLocaleTimeString('ko-KR', {
      hour12: false,
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    })
  }
  return ts
}

export function logEntryToSysRow(entry: LogEntry): SysLogRow {
  const level = entry.level.toLowerCase()
  const identity = entry.keeper_name?.trim() || entry.module?.trim() || '(root)'
  return [logRowClock(entry.ts), level, identity, entry.message, logRowStatus(entry.level)]
}

function SetToggle({ on, onChange }: { on: boolean; onChange: (v: boolean) => void }) {
  return html`
    <button
      type="button"
      class=${`set-toggle ${on ? 'on' : ''}`}
      role="switch"
      aria-checked=${on}
      data-testid="set-toggle"
      onClick=${() => onChange(!on)}
    >
      <span class="knob"></span>
    </button>
  `
}

function SetSeg({
  value,
  options,
  onChange,
}: {
  value: string
  options: string[]
  onChange: (v: string) => void
}) {
  return html`
    <div class="set-seg" data-testid="set-seg">
      ${options.map(o => html`
        <button
          type="button"
          key=${o}
          class=${`set-seg-b ${value === o ? 'on' : ''}`}
          data-active=${value === o ? 'true' : 'false'}
          onClick=${() => onChange(o)}
        >
          ${o}
        </button>
      `)}
    </div>
  `
}

function SetRow({ label, hint, children }: { label: ComponentChildren; hint?: string; children: ComponentChildren }) {
  return html`
    <div class="set-row" data-testid="set-row">
      <div class="set-row-l">
        <div class="set-label">${label}</div>
        ${hint ? html`<div class="set-hint">${hint}</div>` : null}
      </div>
      <div class="set-row-c">${children}</div>
    </div>
  `
}

function SetStepper({
  v,
  set,
  min,
  max,
}: {
  v: number
  set: (n: number) => void
  min: number
  max: number
}) {
  return html`
    <div class="set-stepper" data-testid="set-stepper">
      <button type="button" onClick=${() => set(Math.max(min, v - 1))}>−</button>
      <span class="mono">${v}</span>
      <button type="button" onClick=${() => set(Math.min(max, v + 1))}>+</button>
    </div>
  `
}

function SetSlider({
  value,
  min,
  max,
  step,
  suffix,
  onChange,
}: {
  value: number
  min: number
  max: number
  step?: number
  suffix?: string
  onChange: (n: number) => void
}) {
  return html`
    <div class="set-slider" data-testid="set-slider">
      <input
        type="range"
        min=${min}
        max=${max}
        step=${step ?? 1}
        value=${value}
        onInput=${(e: Event) => onChange(Number((e.target as HTMLInputElement).value))}
      />
      <span class="mono">${value}${suffix ?? ''}</span>
    </div>
  `
}

function VerifyBtn({ label, kind, value }: { label?: string; kind: VerifyResourceKind; value: string }) {
  const [st, setSt] = useState<VerifyState>('idle')
  const [detail, setDetail] = useState('')
  const onClick = (e: Event) => {
    e.stopPropagation()
    setSt('checking')
    setDetail('')
    void (async () => {
      try {
        const res = await verifyResource(kind, value)
        setSt(res.ok ? 'ok' : 'fail')
        setDetail(res.detail)
      } catch (err) {
        // A failed probe must surface as 'fail' — never silently land on 'ok'
        // (that was the old setTimeout fake's defect).
        setSt('fail')
        setDetail(err instanceof Error ? err.message : '검증 실패')
      }
    })()
  }
  const text =
    st === 'idle'
      ? (label ?? '확인')
      : st === 'checking'
        ? '확인 중…'
        : st === 'ok'
          ? '✓ 정상'
          : '✗ 실패'
  return html`
    <button
      type="button"
      class=${`set-verify ${st}`}
      data-state=${st}
      data-testid="set-verify"
      title=${detail}
      onClick=${onClick}
    >
      ${text}
    </button>
  `
}

// Honest placeholder for resources with no in-tree probe yet (Store/DB,
// linked GitHub repo). Disabled — never fabricates a "✓ 정상" (RFC-0273 §3.4
// defers these to a follow-up). Stateless, so no hooks: keeps VerifyBtn's hook
// order unconditional.
function DeferredVerifyBtn() {
  return html`
    <button
      type="button"
      class="set-verify deferred"
      data-state="deferred"
      data-testid="set-verify"
      disabled
      title="자동 검증 미지원 — 수동 확인 필요"
    >
      수동 확인
    </button>
  `
}

function RolePill({ children }: { children: ComponentChildren }) {
  return html`<span class="set-rolepill">${children}</span>`
}

function LogFilter({
  filter,
  active,
  onClick,
}: {
  filter: LogFilter
  active: boolean
  onClick: () => void
}) {
  const label =
    filter === 'all' ? 'All'
    : filter === 'tool' ? 'Tool'
    : filter === 'success' ? 'Success'
    : 'Failure'

  return html`
    <button
      type="button"
      class=${`log-f ${active ? 'on' : ''}`}
      data-filter=${filter}
      data-active=${active ? 'true' : 'false'}
      onClick=${onClick}
    >
      ${label}
    </button>
  `
}

function LogViewer() {
  const [filter, setFilter] = useState<LogFilter>('all')
  const [allRows, setAllRows] = useState<SysLogRow[]>([])
  const [status, setStatus] = useState<'loading' | 'ready' | 'error'>('loading')

  useEffect(() => {
    let active = true
    let timer: ReturnType<typeof setInterval> | null = null

    const tick = async () => {
      try {
        const resp = await fetchLogs({ limit: SETTINGS_LOG_LIMIT })
        if (!active) return
        const rows = [...resp.entries]
          .sort((a, b) => b.seq - a.seq)
          .map(logEntryToSysRow)
        setAllRows(rows)
        setStatus('ready')
      } catch {
        if (!active) return
        // No fabricated rows on failure — surface the error state instead.
        setStatus('error')
      }
    }

    void tick()
    timer = setInterval(() => { void tick() }, SETTINGS_LOG_POLL_MS)

    return () => {
      active = false
      if (timer) clearInterval(timer)
    }
  }, [])

  const rows = allRows.filter(r => {
    if (filter === 'all') return true
    if (filter === 'tool') return /masc_/.test(r[3])
    if (filter === 'success') return r[4] === 'ok'
    if (filter === 'failure') return r[4] === 'fail'
    return true
  })

  const filters: LogFilter[] = ['all', 'tool', 'success', 'failure']
  const emptyLabel =
    status === 'loading' ? '로그를 불러오는 중…'
    : status === 'error' ? '시스템 로그를 불러오지 못했습니다.'
    : '조건에 맞는 로그가 없습니다.'

  return html`
    <div class="log-view" data-testid="log-viewer">
      <div class="log-filters">
        ${filters.map(f => html`
          <${LogFilter}
            key=${f}
            filter=${f}
            active=${filter === f}
            onClick=${() => setFilter(f)}
          />
        `)}
        <span class="log-live"><span class="tps-dot"></span>tail -f</span>
      </div>
      <div class="log-stream mono" data-testid="log-stream">
        ${rows.length === 0
          ? html`<div class="log-empty" data-testid="log-empty">${emptyLabel}</div>`
          : rows.map((r, i) => html`
          <div key=${i} class=${`log-line ${r[1]}`} data-testid="log-row">
            <span class="lt">${r[0]}</span>
            <span class=${`ll ${r[1]}`}>${r[1]}</span>
            <span class="lk">${r[2]}</span>
            <span class="lm">${r[3]}</span>
            <span class=${`ls ${r[4]}`}>
              ${r[4] === 'ok' ? '✓' : r[4] === 'fail' ? '✕' : r[4] === 'warn' ? '⚠' : '·'}
            </span>
          </div>
        `)}
      </div>
    </div>
  `
}

export function SettingsSurface() {
  const [sec, setSec] = useState<SectionId>('account')

  // account
  const [tokenShown, setTokenShown] = useState(false)
  const [sessionExpiry, setSessionExpiry] = useState('8시간')

  // mcp — exposed tools come from the live capability registry (public_mcp surface)
  const [mcpUrl, setMcpUrl] = useState('https://masc.local/mcp')
  const [transport, setTransport] = useState('http')
  const [mcpTools, setMcpTools] = useState<string[]>([])
  const [tools, setTools] = useState<Record<string, boolean>>({})

  useEffect(() => {
    let active = true
    void (async () => {
      try {
        const resp = await fetchDashboardTools()
        if (!active) return
        const names = mcpExposedToolNames(resp.tool_inventory?.tools ?? [])
        setMcpTools(names)
        // Listed tools are, by definition, currently exposed over public MCP.
        // The per-tool toggle is a local view control; expose/unexpose
        // persistence is deferred (no backend write endpoint yet).
        setTools(Object.fromEntries(names.map(n => [n, true])))
      } catch {
        if (!active) return
        // No fabricated tool names on failure.
        setMcpTools([])
        setTools({})
      }
    })()
    return () => { active = false }
  }, [])

  // runtime defaults / model routing — resolved from runtime.toml (SSOT)
  const [runtimeDefaults, setRuntimeDefaults] = useState<RuntimeDefaultsResponse | null>(null)
  const [defRuntime, setDefRuntime] = useState('')
  const [defModel, setDefModel] = useState('')
  const [maxPar, setMaxPar] = useState(6)
  const [compactAt, setCompactAt] = useState(85)
  const [autoCompact, setAutoCompact] = useState(true)

  useEffect(() => {
    let active = true
    void (async () => {
      try {
        const resp = await fetchRuntimeDefaults()
        if (!active) return
        setRuntimeDefaults(resp)
        // Seed the selectors with the resolved defaults (unknown → left blank,
        // never a fabricated default).
        if (resp.default_runtime_id) setDefRuntime(resp.default_runtime_id)
        if (resp.default_model) setDefModel(resp.default_model)
      } catch {
        if (!active) return
        setRuntimeDefaults(null)
      }
    })()
    return () => { active = false }
  }, [])

  // policy
  const [approve, setApprove] = useState<Record<string, string>>(
    Object.fromEntries(APPROVAL_ACTIONS.map(a => [a[0], a[1]])),
  )

  // lifecycle
  const [idleDrain, setIdleDrain] = useState(30)
  const [autoRestart, setAutoRestart] = useState(true)
  const [restartMax, setRestartMax] = useState(3)
  const [onOverflow, setOnOverflow] = useState('자동 compact')

  // gate / paths
  const [gateBase, setGateBase] = useState('https://gate.masc.local')
  const [gateOn, setGateOn] = useState<Record<string, boolean>>({
    Slack: true,
    Discord: true,
    Amplitude: true,
    GitHub: false,
  })
  const [wtBase, setWtBase] = useState('~/wt')
  const [storeUrl, setStoreUrl] = useState('postgres://masc.local:5432/masc')

  // sandbox
  const [isolation, setIsolation] = useState('container')
  const [egress, setEgress] = useState('허용목록')
  const [allowlist, setAllowlist] = useState('github.com, opam.ocaml.org, *.masc.local')
  const [fsScope, setFsScope] = useState('worktree')
  const [shellOn, setShellOn] = useState(true)
  const [blockRisky, setBlockRisky] = useState(true)
  const [memLimit, setMemLimit] = useState('2GB')
  const [cpuLimit, setCpuLimit] = useState(2)
  const [execTimeout, setExecTimeout] = useState(120)

  // ide
  const [ideView, setIdeView] = useState('split-diff')
  const [diffStyle, setDiffStyle] = useState('side-by-side')
  const [tabWidth, setTabWidth] = useState(2)
  const [formatOnSave, setFormatOnSave] = useState(true)
  const [wrapLines, setWrapLines] = useState(false)
  const [liveCursors, setLiveCursors] = useState(true)
  const [ideOwnership, setIdeOwnership] = useState(true)
  const [convRail, setConvRail] = useState(true)
  const [contextLens, setContextLens] = useState(true)
  const [blameGutter, setBlameGutter] = useState(true)
  const [ideAnnos, setIdeAnnos] = useState(true)
  const [annoAutoLink, setAnnoAutoLink] = useState(true)
  const [embedTerminal, setEmbedTerminal] = useState(true)
  const [searchIndex, setSearchIndex] = useState(true)
  const [ideRepo, setIdeRepo] = useState('masc/masc-mcp')

  // prompts
  const [sysPrompt, setSysPrompt] = useState('')
  const [worldPrompt, setWorldPrompt] = useState('')

  // logs
  const [traceKeep, setTraceKeep] = useState('30일')
  const [logLevel, setLogLevel] = useState('info')
  const [sampling, setSampling] = useState(100)

  // notify / display
  const [notifyCtx, setNotifyCtx] = useState(85)
  const [notifyFails, setNotifyFails] = useState(3)
  const [notifyCh, setNotifyCh] = useState('Slack')
  const [notifyOn, setNotifyOn] = useState<Record<string, boolean>>({
    '컨텍스트 임계치 초과': true,
    '연속 실패': true,
    'keeper crash/dead': true,
    '핸드오프 완료': false,
    '승인 요청': true,
  })
  const [density, setDensity] = useState('regular')
  const [tz, setTz] = useState('Asia/Seoul')
  const [locale, setLocale] = useState('KO')
  const [clock24, setClock24] = useState(true)

  const cur = SET_SECTIONS.find(s => s[0] === sec) ?? SET_SECTIONS[0]!

  // Resolved runtime options (de-duplicated, derived from the live registry).
  const runtimeEntries = runtimeDefaults?.runtimes ?? []
  const runtimeIdOptions = runtimeEntries.map(r => r.id)
  const runtimeModelOptions = [...new Set(runtimeEntries.map(r => r.model))]
  const keeperAssignments = runtimeDefaults?.model_routing.keeper_assignments ?? []
  const librarianRuntime = runtimeDefaults?.model_routing.librarian_runtime_id ?? null
  const crossVerifierRuntime = runtimeDefaults?.model_routing.cross_verifier_runtime_id ?? null

  return html`
    <main class="v2-shell-surface settings-surf ss-surface bg-surface-page text-text-primary" data-screen-label="설정" data-testid="settings-surface">
      <div class="set-shell">
        <nav class="set-nav" aria-label="Settings categories">
          <div class="set-nav-h">
            <div class="eyebrow">Operator</div>
            <div class="set-nav-title">Settings</div>
            <div class="set-nav-sub mono">@operator · masc-mcp</div>
          </div>
          ${SET_GROUPS.map(([glabel, ids]) => html`
            <div key=${glabel} class="set-nav-group">
              <div class="set-nav-glabel">${glabel}</div>
              ${ids.map(id => {
                const s = SET_SECTIONS.find(x => x[0] === id)
                if (!s) return null
                return html`
                  <button
                    type="button"
                    key=${id}
                    class=${`set-nav-item ${sec === id ? 'on' : ''}`}
                    data-testid=${`settings-nav-${id}`}
                    data-active=${sec === id ? 'true' : 'false'}
                    onClick=${() => setSec(id)}
                  >
                    <span class="ko">${s[2]}</span>
                    <span class="en mono">${s[1]}</span>
                  </button>
                `
              })}
            </div>
          `)}
          <div class="set-nav-note">Prototype — changes are local-only.</div>
        </nav>

        <div class="set-content">
          <header class="set-content-h">
            <h1 data-testid="settings-section-title">${cur[2]}</h1>
            <button type="button" class="act">Save changes</button>
          </header>

          <div class="set-card-b ss-card mx-6 my-6">
            ${sec === 'account' && html`
              <${SetRow} label="Operator" hint="Currently logged-in operator">
                <span class="mono" style=${{ color: 'var(--text-bright)' }}>@operator</span>
              <//>
              <${SetRow} label="Role" hint="MASC role — DM / player / keeper / operator">
                <${RolePill}>operator<//>
              <//>
              <${SetRow} label="API token" hint="Used for MCP·gate authentication">
                <div class="set-path">
                  <input
                    class="set-input mono"
                    readOnly
                    value=${tokenShown ? 'msc_live_8a4f2c71e0' : '••••••••••••••'}
                  />
                  <button
                    type="button"
                    class="set-verify idle"
                    data-testid="token-toggle"
                    onClick=${() => setTokenShown(v => !v)}
                  >
                    ${tokenShown ? 'Hide' : 'Show'}
                  </button>
                  <button type="button" class="set-verify idle">Reissue</button>
                </div>
              <//>
              <${SetRow} label="Session expiry" hint="Auto-logout timeout">
                <${SetSeg} value=${sessionExpiry} options=${['1시간', '8시간', '안 함']} onChange=${setSessionExpiry} />
              <//>
              <button
                type="button"
                class="set-add"
                style=${{
                  borderColor: 'color-mix(in oklab, var(--status-bad) 40%, transparent)',
                  color: 'var(--status-bad)',
                }}
              >
                Log out
              </button>
            `}

            ${sec === 'mcp' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                Expose this namespace to external agents/clients via an MCP server.
              </div>
              <${SetRow} label="MCP endpoint" hint="GET/POST /mcp">
                <div class="set-path">
                  <input
                    class="set-input mono"
                    value=${mcpUrl}
                    onInput=${(e: Event) => setMcpUrl((e.target as HTMLInputElement).value)}
                  />
                  <${VerifyBtn} kind="mcp_endpoint" value=${mcpUrl} />
                </div>
              <//>
              <${SetRow} label="Transport" hint="transport">
                <${SetSeg} value=${transport} options=${['http', 'stdio', 'sse']} onChange=${setTransport} />
              <//>
              <div class="set-mcp-detail mono">
                ${transport === 'http' && html`<span>POST ${mcpUrl} · Content-Type: application/json · Authorization: Bearer ••••</span>`}
                ${transport === 'stdio' && html`<span>spawn: masc-mcp serve --stdio · framing: ndjson · pid 8421</span>`}
                ${transport === 'sse' && html`<span>GET ${mcpUrl}/sse · keep-alive 15s · event: message</span>`}
              </div>
              <div class="set-sub-h">Exposed tools (${Object.values(tools).filter(Boolean).length}/${mcpTools.length})</div>
              ${mcpTools.length === 0
                ? html`<div class="set-hint" data-testid="mcp-tools-empty">노출된 MCP 도구가 없습니다.</div>`
                : mcpTools.map(t => html`
                <${SetRow} key=${t} label=${html`<span class="mono" style=${{ fontSize: '12.5px' }}>${t}</span>`}>
                  <${SetToggle}
                    on=${tools[t] ?? false}
                    onChange=${(v: boolean) => setTools(p => ({ ...p, [t]: v }))}
                  />
                <//>
              `)}
            `}

            ${sec === 'runtime' && html`
              <${SetRow} label="Default runtime" hint="Resolved from runtime.toml [runtime].default">
                ${runtimeIdOptions.length === 0
                  ? html`<span class="set-hint" data-testid="runtime-default-empty">런타임 설정을 불러오지 못했습니다.</span>`
                  : html`<${SetSeg} value=${defRuntime} options=${runtimeIdOptions} onChange=${setDefRuntime} />`}
              <//>
              <${SetRow} label="Default model" hint="API model of the default runtime">
                ${runtimeModelOptions.length === 0
                  ? html`<span class="set-hint">—</span>`
                  : html`<${SetSeg} value=${defModel} options=${runtimeModelOptions} onChange=${setDefModel} />`}
              <//>
              <${SetRow} label="Max concurrent keepers" hint="In this namespace">
                <${SetStepper} v=${maxPar} set=${setMaxPar} min=${1} max=${12} />
              <//>
              <${SetRow} label="Auto compaction" hint=${`Compact at ${compactAt}% context`}>
                <${SetToggle} on=${autoCompact} onChange=${setAutoCompact} />
              <//>
              ${autoCompact && html`
                <${SetRow} label="Compaction threshold" hint="Window usage basis">
                  <${SetSlider} value=${compactAt} min=${60} max=${95} suffix="%" onChange=${setCompactAt} />
                <//>
              `}
            `}

            ${sec === 'runtimes' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>Registered runtime targets resolved from runtime.toml.</div>
              ${runtimeEntries.length === 0
                ? html`<div class="set-hint" data-testid="runtime-nodes-empty">등록된 런타임이 없습니다.</div>`
                : runtimeEntries.map(rt => html`
                    <div key=${rt.id} class="set-rt" data-testid="runtime-node">
                      <div class="set-rt-top">
                        <span class="set-rt-name mono">${rt.id}</span>
                        <span class="set-rt-kind">${rt.provider}</span>
                        ${rt.is_default ? html`<span class="set-rt-keepers">default</span>` : null}
                      </div>
                      <div class="set-rt-row">
                        <span class="sub-k">model</span>
                        <span class="mono" style=${{ fontSize: '12px', color: 'var(--text-mid)' }}>${rt.model}</span>
                      </div>
                      <div class="set-rt-row">
                        <span class="sub-k">max context</span>
                        <span class="mono" style=${{ fontSize: '12px', color: 'var(--text-mid)' }}>${rt.max_context}</span>
                      </div>
                    </div>
                  `)}
              <button type="button" class="set-add">＋ Add runtime</button>
            `}

            ${sec === 'routing' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                Resolved model routing from runtime.toml (SSOT). Read-only — edit runtime.toml to change.
              </div>
              <${SetRow} label="Default model" hint="Used when no keeper assignment matches">
                <span class="mono" data-testid="routing-default-model">${runtimeDefaults?.default_model ?? '—'}</span>
              <//>
              ${librarianRuntime
                ? html`<${SetRow} label="Librarian runtime" hint="[runtime].librarian"><span class="mono">${librarianRuntime}</span><//>`
                : null}
              ${crossVerifierRuntime
                ? html`<${SetRow} label="Cross-verifier runtime" hint="[runtime].cross_verifier"><span class="mono">${crossVerifierRuntime}</span><//>`
                : null}
              <div class="set-sub-h">Keeper assignments (${keeperAssignments.length})</div>
              ${keeperAssignments.length === 0
                ? html`<div class="set-hint" data-testid="routing-assignments-empty">명시적 keeper 할당이 없습니다 — 모두 기본 런타임을 사용합니다.</div>`
                : keeperAssignments.map(a => html`
                    <${SetRow} key=${a.keeper} label=${a.keeper} hint="keeper → runtime">
                      <span class="mono" data-testid="routing-assignment">${a.runtime_id}</span>
                    <//>
                  `)}
            `}

            ${sec === 'prompts' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                Shared prompt base inherited by every keeper. Keeper-specific persona·instructions layer on top.
                <span class="mono">{'{{keeper}}'} · {'{{namespace}}'} · {'{{runtime}}'} · {'{{model}}'}</span> are substituted per keeper.
              </div>
              <div class="set-sub-h">① System (base) — what a keeper is</div>
              <textarea
                class="set-input mono"
                style=${{ width: '100%', minHeight: '150px', resize: 'vertical', lineHeight: '1.6', padding: '10px 12px', whiteSpace: 'pre' }}
                value=${sysPrompt}
                onInput=${(e: Event) => setSysPrompt((e.target as HTMLTextAreaElement).value)}
              />
              <div class="set-sub-h" style=${{ marginTop: '14px' }}>② World prompt — shared world·rules</div>
              <textarea
                class="set-input mono"
                style=${{ width: '100%', minHeight: '150px', resize: 'vertical', lineHeight: '1.6', padding: '10px 12px', whiteSpace: 'pre' }}
                value=${worldPrompt}
                onInput=${(e: Event) => setWorldPrompt((e.target as HTMLTextAreaElement).value)}
              />
              <div class="set-mcp-detail mono" style=${{ marginTop: '12px' }}>
                Effective prompt = ① System + ② World + ③ persona + ④ instructions · inspect composition in the turn inspector.
              </div>
            `}

            ${sec === 'policy' && html`
              <div class="set-policy-legend">
                <span><b class="mono">always</b> require approval</span>
                <span><b class="mono">risky</b> only when risky</span>
                <span><b class="mono">auto</b> allow automatically</span>
              </div>
              ${APPROVAL_ACTIONS.map(([action, , hint]) => html`
                <${SetRow} key=${action} label=${action} hint=${hint}>
                  <${SetSeg}
                    value=${approve[action]}
                    options=${['always', 'risky', 'auto']}
                    onChange=${(v: string) => setApprove(p => ({ ...p, [action]: v }))}
                  />
                <//>
              `)}
            `}

            ${sec === 'lifecycle' && html`
              <${SetRow} label="Idle auto-drain" hint="Minutes until graceful shutdown">
                <${SetSlider} value=${idleDrain} min=${0} max=${120} step=${5} suffix=${idleDrain ? '분' : '안 함'} onChange=${setIdleDrain} />
              <//>
              <${SetRow} label="Crash auto-restart" hint="Crashed → Restarting attempts">
                <${SetToggle} on=${autoRestart} onChange=${setAutoRestart} />
              <//>
              ${autoRestart && html`
                <${SetRow} label="Max restart attempts" hint="Transition to Dead when exceeded">
                  <${SetStepper} v=${restartMax} set=${setRestartMax} min=${1} max=${10} />
                <//>
              `}
              <${SetRow} label="Overflowed action" hint="When context window overflows">
                <${SetSeg} value=${onOverflow} options=${['자동 compact', '자동 종료', 'operator 대기']} onChange=${setOnOverflow} />
              <//>
            `}

            ${sec === 'sandbox' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                Isolated execution environment for keeper code. Tool permissions (approval policy) sit above this OS·network boundary.
              </div>
              <${SetRow} label="Isolation level" hint="Keeper execution isolation">
                <${SetSeg} value=${isolation} options=${['worktree', 'container', 'microVM']} onChange=${setIsolation} />
              <//>
              <${SetRow} label="Filesystem scope" hint="Paths the keeper can access">
                <${SetSeg} value=${fsScope} options=${['worktree', 'namespace', '전체']} onChange=${setFsScope} />
              <//>
              <${SetRow} label="Network egress" hint="External network access">
                <${SetSeg} value=${egress} options=${['차단', '허용목록', '전체']} onChange=${setEgress} />
              <//>
              ${egress === '허용목록' && html`
                <${SetRow} label="Allowed domains" hint="Comma-separated">
                  <input
                    class="set-input mono"
                    style=${{ width: '260px' }}
                    value=${allowlist}
                    onInput=${(e: Event) => setAllowlist((e.target as HTMLInputElement).value)}
                  />
                <//>
              `}
              <${SetRow} label="Shell commands" hint="Keeper may run shell commands">
                <${SetToggle} on=${shellOn} onChange=${setShellOn} />
              <//>
              ${shellOn && html`
                <${SetRow} label="Block risky commands" hint="rm -rf, curl | sh, etc.">
                  <${SetToggle} on=${blockRisky} onChange=${setBlockRisky} />
                <//>
              `}
              <div class="set-sub-h">Resource limits</div>
              <${SetRow} label="Memory" hint="Max per keeper">
                <${SetSeg} value=${memLimit} options=${['1GB', '2GB', '4GB', '8GB']} onChange=${setMemLimit} />
              <//>
              <${SetRow} label="CPU" hint="vCPU cores">
                <${SetStepper} v=${cpuLimit} set=${setCpuLimit} min=${1} max=${16} />
              <//>
              <${SetRow} label="Execution timeout" hint="Max single command runtime (seconds)">
                <${SetSlider} value=${execTimeout} min=${10} max=${600} step=${10} suffix="s" onChange=${setExecTimeout} />
              <//>
            `}

            ${sec === 'ide' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                Shared IDE behaviour for every keeper: editor, collaboration, code insight and version-control defaults.
              </div>
              <div class="set-sub-h">Editor</div>
              <${SetRow} label="Default view" hint="View when opening a file">
                <${SetSeg} value=${ideView} options=${['source', 'unified', 'split-diff']} onChange=${setIdeView} />
              <//>
              <${SetRow} label="Diff style" hint="Change comparison mode">
                <${SetSeg} value=${diffStyle} options=${['inline', 'side-by-side']} onChange=${setDiffStyle} />
              <//>
              <${SetRow} label="Tab width" hint="Indent columns">
                <${SetStepper} v=${tabWidth} set=${setTabWidth} min=${2} max=${8} />
              <//>
              <${SetRow} label="Format on save" hint="format-on-save">
                <${SetToggle} on=${formatOnSave} onChange=${setFormatOnSave} />
              <//>
              <${SetRow} label="Wrap long lines" hint="word wrap">
                <${SetToggle} on=${wrapLines} onChange=${setWrapLines} />
              <//>

              <div class="set-sub-h">Collaboration (presence)</div>
              <${SetRow} label="Other keeper cursors" hint="Live cursor·selection·focus_mode">
                <${SetToggle} on=${liveCursors} onChange=${setLiveCursors} />
              <//>
              <${SetRow} label="Ownership tint" hint="Keeper color per file/region">
                <${SetToggle} on=${ideOwnership} onChange=${setIdeOwnership} />
              <//>
              <${SetRow} label="Conversation rail" hint="Context panel beside editor">
                <${SetToggle} on=${convRail} onChange=${setConvRail} />
              <//>
              <${SetRow} label="Context lens" hint="Turn·tool event overlay">
                <${SetToggle} on=${contextLens} onChange=${setContextLens} />
              <//>

              <div class="set-sub-h">Code insight</div>
              <${SetRow} label="Blame gutter" hint="Last-change keeper·turn per line">
                <${SetToggle} on=${blameGutter} onChange=${setBlameGutter} />
              <//>
              <${SetRow} label="Inline annotations" hint="goal·task·PR-linked annotations">
                <${SetToggle} on=${ideAnnos} onChange=${setIdeAnnos} />
              <//>
              ${ideAnnos && html`
                <${SetRow} label="Auto-link annotations" hint="Link new annotations to active goal/task/PR">
                  <${SetToggle} on=${annoAutoLink} onChange=${setAnnoAutoLink} />
                <//>
              `}

              <div class="set-sub-h">Execution · Version control</div>
              <${SetRow} label="Embedded terminal" hint="Shell inside IDE — sandbox policy applies">
                <${SetToggle} on=${embedTerminal} onChange=${setEmbedTerminal} />
              <//>
              <${SetRow} label="Search index" hint="Maintain symbol·full-text search index">
                <${SetToggle} on=${searchIndex} onChange=${setSearchIndex} />
              <//>
              <${SetRow} label="Linked repo" hint="diff·PR·blame source — e.g. #7732">
                <div class="set-path">
                  <input
                    class="set-input mono"
                    value=${ideRepo}
                    onInput=${(e: Event) => setIdeRepo((e.target as HTMLInputElement).value)}
                  />
                  <${DeferredVerifyBtn} />
                </div>
              <//>
            `}

            ${sec === 'gate' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                Default settings for external gate connections. Per-channel→keeper bindings are managed in
                <button
                  type="button"
                  class="set-link"
                  onClick=${() => navigate('connectors')}
                >
                  Connectors →
                </button>.
              </div>
              <${SetRow} label="Gate base URL" hint="GET /api/v1/gate/connectors">
                <div class="set-path">
                  <input
                    class="set-input mono"
                    value=${gateBase}
                    onInput=${(e: Event) => setGateBase((e.target as HTMLInputElement).value)}
                  />
                  <${VerifyBtn} kind="gate_url" value=${gateBase} />
                </div>
              <//>
              ${['Slack', 'Discord', 'Amplitude', 'GitHub'].map(g => html`
                <${SetRow} key=${g} label=${g} hint=${gateOn[g] ? 'Connected' : 'Inactive'}>
                  <${SetToggle} on=${gateOn[g]} onChange=${(v: boolean) => setGateOn(p => ({ ...p, [g]: v }))} />
                <//>
              `)}
              <button type="button" class="set-add">＋ Add gate</button>
            `}

            ${sec === 'paths' && html`
              <div class="set-hint" style=${{ marginBottom: '12px' }}>
                Server·store basepaths and keeper worktree root. Each item can be verified.
              </div>
              <${SetRow} label="MCP endpoint" hint="/mcp HTTP entrypoint">
                <div class="set-path">
                  <input
                    class="set-input mono"
                    value=${mcpUrl}
                    onInput=${(e: Event) => setMcpUrl((e.target as HTMLInputElement).value)}
                  />
                  <${VerifyBtn} kind="mcp_endpoint" value=${mcpUrl} />
                </div>
              <//>
              <${SetRow} label="Store (DB)" hint="trace·audit persistence">
                <div class="set-path">
                  <input
                    class="set-input mono"
                    value=${storeUrl}
                    onInput=${(e: Event) => setStoreUrl((e.target as HTMLInputElement).value)}
                  />
                  <${DeferredVerifyBtn} />
                </div>
              <//>
              <${SetRow} label="Default worktree basepath" hint="keeper worktree root — e.g. ~/wt/<keeper>">
                <div class="set-path">
                  <input
                    class="set-input mono"
                    value=${wtBase}
                    onInput=${(e: Event) => setWtBase((e.target as HTMLInputElement).value)}
                  />
                  <${VerifyBtn} kind="worktree_path" value=${wtBase} label="Check path" />
                </div>
              <//>
            `}

            ${sec === 'logs' && html`
              <${SetRow} label="Trace retention" hint="Auto-archive after">
                <${SetSeg} value=${traceKeep} options=${['7일', '30일', '90일']} onChange=${setTraceKeep} />
              <//>
              <${SetRow} label="Log level" hint="Keeper runtime log level">
                <${SetSeg} value=${logLevel} options=${['error', 'warn', 'info', 'debug']} onChange=${setLogLevel} />
              <//>
              <${SetRow} label="Telemetry sampling" hint="Trace collection ratio">
                <${SetSlider} value=${sampling} min=${1} max=${100} suffix="%" onChange=${setSampling} />
              <//>
              <div class="set-sub-h">System log (all keepers · live)</div>
              <${LogViewer} />
            `}

            ${sec === 'notify' && html`
              <${SetRow} label="Context threshold alert" hint="Notify when context exceeds this %">
                <${SetSlider} value=${notifyCtx} min=${70} max=${98} suffix="%" onChange=${setNotifyCtx} />
              <//>
              <${SetRow} label="Consecutive failure alert" hint="Notify after this many consecutive failures">
                <${SetStepper} v=${notifyFails} set=${setNotifyFails} min=${1} max=${10} />
              <//>
              <${SetRow} label="Notify channel" hint="Where to send">
                <${SetSeg} value=${notifyCh} options=${['Slack', 'Discord', '없음']} onChange=${setNotifyCh} />
              <//>
              <div class="set-sub-h">Notify events</div>
              ${Object.keys(notifyOn).map(k => html`
                <${SetRow} key=${k} label=${k}>
                  <${SetToggle} on=${notifyOn[k]} onChange=${(v: boolean) => setNotifyOn(p => ({ ...p, [k]: v }))} />
                <//>
              `)}
            `}

            ${sec === 'display' && html`
              <${SetRow} label="Density" hint="List/card spacing">
                <${SetSeg} value=${density} options=${['compact', 'regular']} onChange=${setDensity} />
              <//>
              <${SetRow} label="Language" hint="UI labels">
                <${SetSeg} value=${locale} options=${['KO', 'EN']} onChange=${setLocale} />
              <//>
              <${SetRow} label="Timezone" hint="Timestamp basis">
                <${SetSeg} value=${tz} options=${['Asia/Seoul', 'Asia/Tokyo', 'UTC']} onChange=${setTz} />
              <//>
              <${SetRow} label="24-hour clock" hint="Time format">
                <${SetToggle} on=${clock24} onChange=${setClock24} />
              <//>
            `}
          </div>
        </div>
      </div>
    </main>
  `
}
