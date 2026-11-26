/**
 * Left 260px Virtualized Keeper Roster + `+ Create Keeper` (`target=keeper_create`) Schema Drawer.
 */

import { html } from 'htm/preact'
import { isWaitingUnavailable } from './turn-context'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { formatObserved, type Observed } from '../../core/resource-cache'
import { KeeperBadge } from '../../components/keeper-badge'
import { VirtualList } from '../../components/primitives/virtual-list'
import {
  fetchConfigSchemaApi,
  patchOpForField,
  postConfigPatchApi,
  type ConfigPatchChange,
  type ConfigPatchResult,
  type ConfigSchemaData,
} from '../../api/config-schema'
import {
  filterAndSortRoster,
  formatContextDetail,
  isKeeperPathResting,
  needsRosterAttention,
  observeRosterContextPct,
} from './keepers-api'
import type {
  KeeperRosterItem,
  RosterMode,
} from './types'

export interface KeeperRosterProps {
  readonly roster: Observed<readonly KeeperRosterItem[]>
  readonly selectedKeeper: string | null
  readonly onSelectKeeper: (name: string) => void
  readonly onCreatedKeeper: (name: string) => void
}

function waitingSubLine(k: KeeperRosterItem): string {
  if (isWaitingUnavailable(k.waiting_summary)) return `대기 목록 읽기 실패 · ${k.runtime_id}`
  return k.waiting_summary && k.waiting_summary.count > 0
    ? `대기 ${k.waiting_summary.count} · ${k.runtime_id}`
    : k.runtime_id
}

function healthDotTone(k: KeeperRosterItem): 'ok' | 'warn' | 'bad' | 'brass' | 'idle' {
  if (needsRosterAttention(k)) return 'bad'
  if (isKeeperPathResting(k) || k.paused) return 'warn'
  if (k.active_turn) return 'brass'
  if (k.keepalive_running) return 'ok'
  return 'idle'
}

export function KeeperRoster(props: KeeperRosterProps) {
  const [mode, setMode] = useState<RosterMode>('companies')
  const [query, setQuery] = useState('')
  const [createOpen, setCreateOpen] = useState(false)

  const items: readonly KeeperRosterItem[] = props.roster.kind === 'value' ? props.roster.data : []

  const visible = useMemo(
    () => filterAndSortRoster(items, mode, query),
    [items, mode, query],
  )

  return html`
    <aside class="kp-roster" aria-label="Keeper 로스터">
      <div class="kp-roster-head">
        <div class="kp-roster-top">
          <h2 class="kp-roster-title">
            <span class="kp-roster-title-text" title=${`Keepers (${items.length})`}>Keepers (${items.length})</span>
            ${props.roster.kind === 'value' && props.roster.stale && html`
              <span class="kp-pill" data-tone="warn">지연됨</span>
            `}
          </h2>
          <button
            type="button"
            class="btn-primary"
            onClick=${() => setCreateOpen(true)}
          >
            + Create Keeper
          </button>
        </div>

        <input
          type="search"
          class="kp-input"
          placeholder="Keeper, 회사, 런타임 검색…"
          aria-label="Keeper 검색"
          value=${query}
          onInput=${(e: Event) => setQuery((e.currentTarget as HTMLInputElement).value)}
        />

        <div class="kp-modes" role="group" aria-label="로스터 정렬 모드">
          <button
            type="button"
            class="kp-mode-btn"
            aria-pressed=${mode === 'companies' ? 'true' : 'false'}
            onClick=${() => setMode('companies')}
          >
            Companies
          </button>
          <button
            type="button"
            class="kp-mode-btn"
            aria-pressed=${mode === 'attention' ? 'true' : 'false'}
            onClick=${() => setMode('attention')}
          >
            Attention
          </button>
          <button
            type="button"
            class="kp-mode-btn"
            aria-pressed=${mode === 'wall24h' ? 'true' : 'false'}
            onClick=${() => setMode('wall24h')}
          >
            24h Wall
          </button>
        </div>
      </div>

      ${props.roster.kind === 'loading'
        ? html`<div class="kp-empty">로스터 불러오는 중…</div>`
        : props.roster.kind === 'failed'
          ? html`<div class="ap-error" role="alert">${props.roster.error.message}</div>`
          : html`
              <${VirtualList}
                className="kp-roster-list"
                items=${visible}
                estimateSize=${60}
                height="100%"
                ariaLabel="Keeper 목록"
                getItemKey=${(k: KeeperRosterItem) => k.name}
                empty=${html`<div class="kp-empty">일치하는 Keeper 없음</div>`}
                renderItem=${(k: KeeperRosterItem) => {
                  const ctxObs = observeRosterContextPct(k)
                  const ctxDetail = formatContextDetail(k)
                  const ctxLabel = ctxObs.kind === 'value' ? ctxDetail.label : formatObserved(ctxObs, (v) => `${v}%`)
                  const ctxTone = ctxObs.kind !== 'value'
                    ? undefined
                    : ctxObs.data >= 85
                      ? 'bad'
                      : ctxObs.data >= 65
                        ? 'warn'
                        : 'ok'
                  const resting = isKeeperPathResting(k)
                  const failing = needsRosterAttention(k)
                  const selected = props.selectedKeeper === k.name
                  const subLine = failing
                    ? `⚠ ${k.runtime_blocker_summary ?? k.last_failure?.cause ?? k.directory_issue ?? k.health}`
                    : resting
                      ? `⏸ 휴식 · ${k.runtime_path_rest?.runtime_id ?? k.runtime_id}`
                      : waitingSubLine(k)
                  const actionableDisposition =
                    k.operator_disposition && k.operator_disposition !== 'pass'
                      ? k.operator_disposition
                      : null
                  const rightSub = mode === 'wall24h'
                    ? (k.turns_24h_breakdown && k.turns_24h_breakdown.failed > 0
                        ? `${k.turns_24h_breakdown.ok}ok/${k.turns_24h_breakdown.failed}fail`
                        : k.turns_24h !== null
                          ? `${k.turns_24h}t/24h`
                          : '없음')
                    : mode === 'attention' && failing
                      ? `⚠ ${actionableDisposition ?? k.health}`
                      : mode === 'attention' && resting
                        ? '⏸ 휴식'
                        : k.company
                  return html`
                    <button
                      type="button"
                      class="kp-roster-row"
                      data-keeper=${k.name}
                      data-selected=${selected ? 'true' : 'false'}
                      aria-current=${selected ? 'true' : undefined}
                      onClick=${() => props.onSelectKeeper(k.name)}
                    >
                      <span class="kp-roster-avatar">
                        <${KeeperBadge}
                          id=${k.name}
                          size="md"
                          variant="sigil"
                          portrait=${true}
                          beat=${k.active_turn !== null}
                        />
                        <span class="kp-status-dot" data-tone=${healthDotTone(k)} />
                      </span>
                      <span class="kp-roster-info">
                        <span class="kp-roster-name">${k.name}</span>
                        <span class="kp-roster-sub" title=${subLine}>
                          ${subLine}
                        </span>
                      </span>
                      <span class="kp-roster-right">
                        <span class="kp-pill" data-ctx="true" data-tone=${ctxTone} title=${ctxDetail.tooltip}>
                          Ctx ${ctxLabel}
                        </span>
                        <span class="kp-roster-sub" title=${rightSub}>
                          ${rightSub}
                        </span>
                      </span>
                    </button>
                  `
                }}
              />
            `}

      ${createOpen && html`
        <${CreateKeeperModal}
          onClose=${() => setCreateOpen(false)}
          onCreated=${(name: string) => {
            setCreateOpen(false)
            props.onCreatedKeeper(name)
          }}
        />
      `}
    </aside>
  `
}

interface CreateKeeperModalProps {
  readonly onClose: () => void
  readonly onCreated: (name: string) => void
}

function CreateKeeperModal(props: CreateKeeperModalProps) {
  const [schema, setSchema] = useState<ConfigSchemaData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [keeperName, setKeeperName] = useState('')
  const [draftValues, setDraftValues] = useState<Record<string, string>>({})
  const [preview, setPreview] = useState<ConfigPatchResult | null>(null)
  const [busy, setBusy] = useState(false)
  const nameInputRef = useRef<HTMLInputElement>(null)
  const onCloseRef = useRef(props.onClose)
  onCloseRef.current = props.onClose

  useEffect(() => {
    queueMicrotask(() => nameInputRef.current?.focus())
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return
      if (event.key === 'Escape') {
        event.preventDefault()
        event.stopPropagation()
        onCloseRef.current()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  useEffect(() => {
    let active = true
    void fetchConfigSchemaApi('keeper_create').then((res) => {
      if (!active) return
      setLoading(false)
      if (!res.ok) {
        setError(res.error.message)
        return
      }
      setSchema(res.value)
    })
    return () => { active = false }
  }, [])

  const editableFields = useMemo(() => {
    if (!schema) return []
    return schema.categories
      .flatMap((c) => c.fields)
      .filter((f) => f.writable && !f.secret)
      .slice(0, 12)
  }, [schema])

  const buildChanges = (): ConfigPatchChange[] => {
    const changes: ConfigPatchChange[] = []
    for (const field of editableFields) {
      const raw = draftValues[field.full_key]
      if (raw === undefined || raw.trim() === '') continue
      const change = patchOpForField(field, raw.trim(), false, ',')
      if (change) changes.push(change)
    }
    return changes
  }

  const runPatch = async (dryRun: boolean) => {
    const trimmed = keeperName.trim()
    if (!trimmed) {
      setError('Keeper 이름(소문자/숫자/하이픈)을 입력하세요.')
      return
    }
    setBusy(true)
    setError(null)
    const res = await postConfigPatchApi({
      target: 'keeper_create',
      keeperName: trimmed,
      dryRun,
      changes: buildChanges(),
    })
    setBusy(false)
    if (!res.ok) {
      setError(res.error.message)
      return
    }
    setPreview(res.value)
    if (!dryRun && res.value.applied) {
      props.onCreated(trimmed)
    }
  }

  return html`
    <div
      class="kp-modal-backdrop"
      role="dialog"
      aria-modal="true"
      aria-label="새 Keeper 생성"
      onClick=${(e: MouseEvent) => {
        if (e.target === e.currentTarget) props.onClose()
      }}
    >
      <div class="kp-modal">
        <div class="kp-card-head">
          <h3>+ Create Keeper (target=keeper_create)</h3>
          <button type="button" class="btn-ghost" onClick=${props.onClose}>닫기</button>
        </div>

        ${error && html`<div class="ap-error" role="alert">${error}</div>`}

        <label class="kp-kv-box">
          <span class="kp-kv-k">Keeper Name (필수)</span>
          <input
            ref=${nameInputRef}
            type="text"
            class="kp-input"
            placeholder="e.g. code-reviewer-alpha"
            value=${keeperName}
            onInput=${(e: Event) => setKeeperName((e.currentTarget as HTMLInputElement).value)}
          />
        </label>

        ${loading
          ? html`<div class="kp-empty">keeper_create 스키마 불러오는 중…</div>`
          : html`
              <div>
                ${editableFields.map((field) => html`
                  <div key=${field.full_key} class="kp-field-row">
                    <div>
                      <div class="kp-roster-name">${field.label ?? field.full_key}</div>
                      ${field.description
                        ? html`<${MarkdownContent} class="kp-roster-sub" text=${field.description} />`
                        : html`<div class="kp-roster-sub">${field.type}</div>`}
                    </div>
                    ${field.enum_values && field.enum_values.length > 0
                      ? html`
                          <select
                            class="kp-input"
                            value=${draftValues[field.full_key] ?? ''}
                            onChange=${(e: Event) => setDraftValues({
                              ...draftValues,
                              [field.full_key]: (e.currentTarget as HTMLSelectElement).value,
                            })}
                          >
                            <option value="">(기본값: ${String(field.default_value ?? '없음')})</option>
                            ${field.enum_values.map((v) => html`<option key=${v} value=${v}>${v}</option>`)}
                          </select>
                        `
                      : html`
                          <input
                            type="text"
                            class="kp-input"
                            placeholder=${String(field.default_value ?? '')}
                            value=${draftValues[field.full_key] ?? ''}
                            onInput=${(e: Event) => setDraftValues({
                              ...draftValues,
                              [field.full_key]: (e.currentTarget as HTMLInputElement).value,
                            })}
                          />
                        `}
                  </div>
                `)}
              </div>
            `}

        ${preview && html`
          <div>
            <div class="kp-pill-row">
              <span class="kp-pill" data-tone="info">reload: ${preview.reload_scope}</span>
              ${preview.validation_warnings.map((w, i) => html`
                <span key=${i} class="kp-pill" data-tone="warn">⚠ ${w}</span>
              `)}
            </div>
            <pre class="kp-diff">${preview.unified_diff || '(변경 diff 없음)'}</pre>
          </div>
        `}

        <div class="kp-lifecycle-bar">
          <button type="button" class="btn-ghost" disabled=${busy} onClick=${() => void runPatch(true)}>
            Dry-Run Diff 미리보기
          </button>
          <button type="button" class="btn-primary" disabled=${busy} onClick=${() => void runPatch(false)}>
            Keeper 생성 적용
          </button>
        </div>
      </div>
    </div>
  `
}
