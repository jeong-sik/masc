/**
 * Keeper Company / Group Organizer Bar.
 *
 * - Fetches groups from `GET /api/v1/dashboard/shell` alongside live Keepers.
 * - Normalizes ungrouped sentinel (`"ungrouped"`, `null`, `""`) to `"미지정"` and always sorts it last.
 * - Renders collapsible group chips/cards with member / active / fault counts, click-to-filter,
 *   per-group collapse state persisted in `localStorage`, and an inline "그룹 지정" editor
 *   that updates `keeper.group` via CAS `POST /api/v1/config/patch`.
 */

import { html } from 'htm/preact'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { fetchConfigSchemaApi, postConfigPatchApi } from '../../api/config-schema'
import { authSession, isSingleUserMember, sessionEpoch } from '../../core/auth'
import { apiGet } from '../../core/transport'
import { persistentSignal } from '../../lib/persisted-ui-signal'
import { isAdminLockedForSession } from '../../routes/router'
import type { KeeperRosterItem } from './types'

export const UNGROUPED_LABEL = '미지정'

export interface ShellGroupEntry {
  readonly name?: string | null
  readonly id?: string | null
  readonly keepers?: readonly string[]
}

export interface KeeperGroupSummary {
  readonly name: string
  readonly isUngrouped: boolean
  readonly memberCount: number
  readonly activeCount: number
  readonly faultCount: number
  readonly members: readonly KeeperRosterItem[]
}

export interface KeeperGroupBarProps {
  readonly keepers: readonly KeeperRosterItem[]
  readonly selectedGroup: string | null
  readonly onSelectGroup: (group: string | null) => void
  readonly activeKeeper: KeeperRosterItem | null
  readonly onSelectKeeper?: (name: string) => void
  readonly onGroupAssigned?: () => void
}

export const groupBarCollapsed = persistentSignal<boolean>({
  key: 'masc:keepers:group-bar-collapsed:v1',
  defaultValue: false,
})

export const collapsedGroupNames = persistentSignal<readonly string[]>({
  key: 'masc:keepers:group-collapsed:v1',
  defaultValue: [],
  deserialize: (raw) => {
    const parsed: unknown = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed.filter((v): v is string => typeof v === 'string') : []
  },
})

/** Normalize `"ungrouped"` / `"general"` / `null` / `undefined` / `""` to `"미지정"`. */
export function normalizeKeeperGroup(raw: string | null | undefined): string {
  if (typeof raw !== 'string') return UNGROUPED_LABEL
  const trimmed = raw.trim()
  const lower = trimmed.toLowerCase()
  if (!trimmed || lower === 'ungrouped' || lower === 'general' || trimmed === UNGROUPED_LABEL) {
    return UNGROUPED_LABEL
  }
  return trimmed
}

function isKeeperFaulted(k: KeeperRosterItem): boolean {
  const h = k.health.toLowerCase()
  return (
    h === 'unhealthy'
    || h === 'fault'
    || h === 'error'
    || h === 'degraded'
    || k.last_failure !== null
    || k.runtime_blocker_summary !== null
    || k.directory_issue !== null
  )
}

function isKeeperActive(k: KeeperRosterItem): boolean {
  return k.keepalive_running || k.active_turn !== null
}

/**
 * Pure: merges shell group declarations with live Keepers, computes counts,
 * and sorts named groups alphabetically with `"미지정"` always last.
 */
export function buildKeeperGroupSummaries(
  keepers: readonly KeeperRosterItem[],
  shellGroups: readonly ShellGroupEntry[] = [],
): readonly KeeperGroupSummary[] {
  const byGroup = new Map<string, KeeperRosterItem[]>()

  for (const g of shellGroups) {
    const rawName = typeof g.name === 'string' ? g.name : typeof g.id === 'string' ? g.id : null
    if (!rawName) continue
    const normalized = normalizeKeeperGroup(rawName)
    if (!byGroup.has(normalized)) {
      byGroup.set(normalized, [])
    }
  }

  for (const keeper of keepers) {
    const groupName = normalizeKeeperGroup(keeper.company)
    const list = byGroup.get(groupName)
    if (list) list.push(keeper)
    else byGroup.set(groupName, [keeper])
  }

  const summaries: KeeperGroupSummary[] = []
  for (const [name, members] of byGroup.entries()) {
    const isUngrouped = name === UNGROUPED_LABEL
    // Omit empty "미지정" unless there are actual ungrouped keepers.
    if (isUngrouped && members.length === 0) continue
    let activeCount = 0
    let faultCount = 0
    for (const m of members) {
      if (isKeeperActive(m)) activeCount += 1
      if (isKeeperFaulted(m)) faultCount += 1
    }
    summaries.push({
      name,
      isUngrouped,
      memberCount: members.length,
      activeCount,
      faultCount,
      members,
    })
  }

  summaries.sort((a, b) => {
    if (a.isUngrouped && !b.isUngrouped) return 1
    if (!a.isUngrouped && b.isUngrouped) return -1
    return a.name.localeCompare(b.name, 'ko')
  })

  return summaries
}

export async function assignKeeperGroupApi(
  keeperName: string,
  nextGroupRaw: string,
): Promise<{ readonly ok: true } | { readonly ok: false; readonly message: string }> {
  const trimmed = nextGroupRaw.trim()
  const lower = trimmed.toLowerCase()
  const value =
    !trimmed || lower === 'ungrouped' || lower === 'general' || trimmed === UNGROUPED_LABEL
      ? ''
      : trimmed

  const target = `keeper:${keeperName}`
  const schemaRes = await fetchConfigSchemaApi(target)
  if (!schemaRes.ok) {
    return { ok: false, message: `설정 스키마 조회 실패: ${schemaRes.error.message}` }
  }
  const expectedSha256 = schemaRes.value.file_sha256
  if (!expectedSha256) {
    return { ok: false, message: '설정 체크섬(file_sha256)을 확인할 수 없습니다.' }
  }

  const patchRes = await postConfigPatchApi({
    target,
    expectedSha256,
    dryRun: false,
    changes: [
      {
        op: 'set',
        table: 'keeper',
        key: 'group',
        full_key: 'keeper.group',
        value,
      },
    ],
  })

  if (!patchRes.ok) {
    return { ok: false, message: patchRes.error.message }
  }
  return { ok: true }
}

export function KeeperGroupBar(props: KeeperGroupBarProps) {
  const { keepers, selectedGroup, onSelectGroup, activeKeeper, onSelectKeeper, onGroupAssigned } = props
  const session = authSession.value
  const isSingleUser = isSingleUserMember(session)
  const adminLocked = isAdminLockedForSession('admin', session)
  const epoch = sessionEpoch.value

  const [shellGroups, setShellGroups] = useState<readonly ShellGroupEntry[]>([])
  const [shellLoadError, setShellLoadError] = useState<string | null>(null)
  const [assignOpen, setAssignOpen] = useState(false)
  const [assignDraft, setAssignDraft] = useState('')
  const [assignBusy, setAssignBusy] = useState(false)
  const [assignStatus, setAssignStatus] = useState<{ readonly tone: 'ok' | 'err'; readonly text: string } | null>(null)
  const mountedRef = useRef(true)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  useEffect(() => {
    if (!isSingleUser) {
      setShellGroups([])
      setShellLoadError(null)
      return
    }
    const ctrl = new AbortController()
    void apiGet<{ readonly groups?: readonly ShellGroupEntry[] }>('/api/v1/dashboard/shell', {
      signal: ctrl.signal,
    }).then((res) => {
      if (!mountedRef.current || ctrl.signal.aborted) return
      if (res.ok && Array.isArray(res.value.groups)) {
        setShellGroups(res.value.groups)
        setShellLoadError(null)
      } else if (!res.ok) {
        setShellLoadError(res.error.message)
      } else {
        setShellLoadError('응답 형식 오류')
      }
    })
    return () => ctrl.abort()
  }, [isSingleUser, epoch])

  useEffect(() => {
    if (activeKeeper) {
      const normalized = normalizeKeeperGroup(activeKeeper.company)
      setAssignDraft(normalized === UNGROUPED_LABEL ? '' : normalized)
    }
    setAssignStatus(null)
  }, [activeKeeper?.name, activeKeeper?.company])

  const summaries = useMemo(
    () => buildKeeperGroupSummaries(keepers, shellGroups),
    [keepers, shellGroups],
  )

  const autocompleteGroups = useMemo(
    () => summaries.filter((g) => !g.isUngrouped).map((g) => g.name),
    [summaries],
  )

  const barCollapsed = groupBarCollapsed.value
  const collapsedSet = useMemo(() => new Set(collapsedGroupNames.value), [collapsedGroupNames.value])

  const toggleGroupCard = useCallback((name: string) => {
    const next = new Set(collapsedGroupNames.peek())
    if (next.has(name)) next.delete(name)
    else next.add(name)
    collapsedGroupNames.value = [...next]
  }, [])

  const handleAssignSubmit = useCallback(
    async (ev: Event) => {
      ev.preventDefault()
      if (!activeKeeper || assignBusy || adminLocked) return
      setAssignBusy(true)
      setAssignStatus(null)
      const res = await assignKeeperGroupApi(activeKeeper.name, assignDraft)
      if (!mountedRef.current) return
      setAssignBusy(false)
      if (!res.ok) {
        setAssignStatus({ tone: 'err', text: `그룹 지정 실패: ${res.message}` })
        return
      }
      setAssignStatus({
        tone: 'ok',
        text: `${activeKeeper.name} → ${normalizeKeeperGroup(assignDraft)} 저장됨`,
      })
      setAssignOpen(false)
      onGroupAssigned?.()
    },
    [activeKeeper, assignBusy, adminLocked, assignDraft, onGroupAssigned],
  )

  if (keepers.length === 0 && summaries.length === 0) return null

  return html`
    <section
      class="kgb-bar"
      aria-label="Keeper 그룹 구성"
      data-testid="keeper-group-bar"
      data-collapsed=${barCollapsed ? 'true' : 'false'}
    >
      <div class="kgb-head">
        <div class="kgb-head-left">
          <button
            type="button"
            class="btn-ghost btn-compact"
            aria-expanded=${!barCollapsed ? 'true' : 'false'}
            data-testid="kgb-toggle"
            onClick=${() => { groupBarCollapsed.value = !barCollapsed }}
          >
            ${barCollapsed ? '▸' : '▾'} 그룹 (${summaries.length})
          </button>
          ${selectedGroup && html`
            <button
              type="button"
              class="kgb-active-filter"
              data-testid="kgb-clear-filter"
              onClick=${() => onSelectGroup(null)}
              title="그룹 필터 해제"
            >
              필터: ${selectedGroup} ✕
            </button>
          `}
        </div>

        <div class="kgb-head-actions">
          ${shellLoadError && html`
            <span
              class="kp-pill"
              data-tone="warn"
              role="status"
              data-testid="kgb-shell-error"
              title=${`그룹 목록 조회 실패: ${shellLoadError}`}
            >
              그룹 목록 일부 미반영
            </span>
          `}
          ${assignStatus && html`
            <span
              class="kp-pill"
              data-tone=${assignStatus.tone === 'ok' ? 'ok' : 'bad'}
              role="status"
              data-testid="kgb-assign-status"
            >
              ${assignStatus.text}
            </span>
          `}
          ${!adminLocked && activeKeeper && html`
            <button
              type="button"
              class="btn-ghost btn-compact"
              aria-expanded=${assignOpen ? 'true' : 'false'}
              data-testid="kgb-assign-toggle"
              onClick=${() => setAssignOpen((v) => !v)}
            >
              그룹 지정
            </button>
          `}
        </div>
      </div>

      ${assignOpen && activeKeeper && !adminLocked && html`
        <form class="kgb-assign-form" data-testid="kgb-assign-form" onSubmit=${handleAssignSubmit}>
          <label class="kgb-assign-label" for="kgb-group-input">
            <span class="mono">${activeKeeper.name}</span> 그룹:
          </label>
          <input
            id="kgb-group-input"
            type="text"
            list="kgb-group-datalist"
            class="kp-input kgb-assign-input"
            placeholder="그룹명 입력 (비우면 미지정)…"
            value=${assignDraft}
            onInput=${(e: Event) => setAssignDraft((e.currentTarget as HTMLInputElement).value)}
          />
          <datalist id="kgb-group-datalist">
            ${autocompleteGroups.map((g) => html`<option key=${g} value=${g} />`)}
          </datalist>
          <button type="submit" class="btn-primary btn-compact" disabled=${assignBusy} data-testid="kgb-assign-save">
            ${assignBusy ? '저장 중…' : '적용'}
          </button>
          <button type="button" class="btn-ghost btn-compact" onClick=${() => setAssignOpen(false)}>
            취소
          </button>
        </form>
      `}

      ${!barCollapsed && html`
        <div class="kgb-chips" role="list">
          <button
            type="button"
            class=${`kgb-chip ${selectedGroup === null ? 'is-selected' : ''}`.trim()}
            aria-pressed=${selectedGroup === null ? 'true' : 'false'}
            data-testid="kgb-chip-all"
            onClick=${() => onSelectGroup(null)}
          >
            <span class="kgb-chip-name">전체</span>
            <span class="mono tnum kgb-chip-stat">${keepers.length}</span>
          </button>

          ${summaries.map((group) => {
            const isSelected = selectedGroup === group.name
            const isCardCollapsed = collapsedSet.has(group.name)
            return html`
              <div
                key=${group.name}
                role="listitem"
                class=${`kgb-chip-card ${isSelected ? 'is-selected' : ''}`.trim()}
                data-testid=${`kgb-group-${group.isUngrouped ? 'ungrouped' : group.name}`}
              >
                <div class="kgb-chip-row">
                  <button
                    type="button"
                    class="kgb-chip-btn"
                    aria-pressed=${isSelected ? 'true' : 'false'}
                    onClick=${() => onSelectGroup(isSelected ? null : group.name)}
                    title=${`${group.name} (${group.memberCount}명 · 활성 ${group.activeCount} · 오류 ${group.faultCount})`}
                  >
                    <span class="kgb-chip-name">${group.name}</span>
                    <span class="mono tnum kgb-chip-stat">${group.memberCount}</span>
                    ${group.activeCount > 0 && html`
                      <span class="mono tnum kgb-chip-active" title="활성 Keeper">●${group.activeCount}</span>
                    `}
                    ${group.faultCount > 0 && html`
                      <span class="mono tnum kgb-chip-fault" title="오류/주의 Keeper">!${group.faultCount}</span>
                    `}
                  </button>
                  ${group.members.length > 0 && html`
                    <button
                      type="button"
                      class="kgb-chip-expand"
                      aria-label=${`${group.name} 멤버 ${isCardCollapsed ? '펼치기' : '접기'}`}
                      aria-expanded=${!isCardCollapsed ? 'true' : 'false'}
                      onClick=${() => toggleGroupCard(group.name)}
                    >
                      ${isCardCollapsed ? '▸' : '▾'}
                    </button>
                  `}
                </div>
                ${!isCardCollapsed && group.members.length > 0 && isSelected && html`
                  <div class="kgb-member-list">
                    ${group.members.map((m) => html`
                      <button
                        key=${m.name}
                        type="button"
                        class=${`kgb-member-pill mono ${activeKeeper?.name === m.name ? 'is-active' : ''}`.trim()}
                        onClick=${() => onSelectKeeper?.(m.name)}
                      >
                        ${m.name}
                      </button>
                    `)}
                  </div>
                `}
              </div>
            `
          })}
        </div>
      `}
    </section>
  `
}
