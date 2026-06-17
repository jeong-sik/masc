import { html } from 'htm/preact'
import {
  cx,
  MgEntry,
  MgSig,
  type MemoryKeeper,
  type MemoryNodeType,
} from './memory-primitives'

export interface GoalDossierGoal {
  readonly title: string
  readonly kp: string
  readonly ns: string
  readonly pct: number
  readonly deadline?: string
}

export interface GoalDossierSnap {
  readonly t: string
  readonly pct: number
  readonly note: string
  readonly now?: boolean
}

export interface GoalDossierRelatedItem {
  readonly title: string
  readonly kp: string
  readonly meta: string
  readonly state: 'done' | 'open' | 'block' | 'ctx'
}

export interface GoalDossierRelatedGroups {
  readonly task?: ReadonlyArray<GoalDossierRelatedItem>
  readonly issue?: ReadonlyArray<GoalDossierRelatedItem>
  readonly memory?: ReadonlyArray<GoalDossierRelatedItem>
}

export interface GoalDossierProps {
  readonly goal: GoalDossierGoal
  readonly nodeTypes: Readonly<Record<string, MemoryNodeType>>
  readonly keepers?: Readonly<Record<string, MemoryKeeper>>
  readonly snaps: ReadonlyArray<GoalDossierSnap>
  readonly related: GoalDossierRelatedGroups
  readonly ledger?: ReadonlyArray<readonly [string, string]>
  readonly ariaLabel?: string
  readonly testId?: string
}

const STATE_LABEL: Record<GoalDossierRelatedItem['state'], string> = {
  done: '완료',
  open: '진행',
  block: '차단',
  ctx: '맥락',
}

const GROUP_KEYS: Array<keyof GoalDossierRelatedGroups> = ['task', 'issue', 'memory']

export function GoalDossier({
  goal,
  nodeTypes,
  keepers = {},
  snaps,
  related,
  ledger = [],
  ariaLabel = '목표 도시에',
  testId,
}: GoalDossierProps) {
  const snapshotType = nodeTypes.snapshot ?? { kr: '스냅샷', g: '◷', c: 'var(--accent-ice)' }

  return html`
    <div class="mg-board gd-board" data-testid=${testId} aria-label=${ariaLabel}>
      <${MgEntry} extra="목표 중심 · 얼만큼 일했나" />
      <div class="gd-head">
        <div class="gd-head-l">
          <span class="gd-glyph">◎</span>
          <div style=${{ minWidth: 0 }}>
            <div class="gd-ey">골 · ${goal.ns}</div>
            <div class="gd-title">${goal.title}</div>
            <div class="gd-sub">
              <${MgSig} kp=${goal.kp} keepers=${keepers} size=${15} />
              <span class="mono">${goal.kp}</span>
              <span class="mono dimd">소유${goal.deadline ? ` · ${goal.deadline}` : ''}</span>
            </div>
          </div>
        </div>
        <div
          class="gd-ring"
          style=${{
            background: `conic-gradient(var(--volt) 0 ${goal.pct}%, var(--border-main) ${goal.pct}% 100%)`,
          }}
        >
          <div class="gd-ring-in">
            <b>${goal.pct}%</b><span>진척</span>
          </div>
        </div>
      </div>

      <div class="gd-snapwrap">
        <div class="gd-prog">
          <span class="gd-prog-fill" style=${{ width: `${goal.pct}%` }} />
        </div>
        <div class="gd-snaps">
          <span class="gd-snaplbl">
            <span class="g" style=${{ color: snapshotType.c }}>${snapshotType.g}</span>
            ${snapshotType.kr}
          </span>
          ${snaps.map((s, i) => html`
            <span key=${i}>
              ${i > 0 ? html`<span class="gd-snaparr">→</span>` : null}
              <span class=${cx('gd-snap', s.now && 'now')}>
                <b class="mono">${s.pct}%</b>
                <span class="mono dt">${s.t}</span>
                <span class="nt">${s.note}</span>
              </span>
            </span>
          `)}
        </div>
      </div>

      <div class="gd-ledger">
        ${ledger.map(([k2, v], i) => html`
          <div key=${i} class="gd-cell">
            <div class="gd-cv mono">${v}</div>
            <div class="gd-ck">${k2}</div>
          </div>
        `)}
      </div>

      <div class="gd-groups">
        ${GROUP_KEYS.map((tk) => {
          const t = nodeTypes[tk]
          const items = related[tk]
          if (!t || !items || items.length === 0) return null
          return html`
            <div key=${tk} class="gd-group" style=${{ '--nc': t.c }}>
              <div class="gd-group-h">
                <span class="g">${t.g}</span>${t.kr}
                <span class="cnt mono">${items.length}</span>
              </div>
              ${items.map((it, j) => html`
                <div key=${j} class=${cx('gd-crow', `st-${it.state}`)}>
                  <div class="gd-cmain">
                    <div class="gd-ctitle">${it.title}</div>
                    <div class="gd-cmeta">
                      <${MgSig} kp=${it.kp} keepers=${keepers} size=${13} />
                      <span class="mono">${it.meta}</span>
                    </div>
                  </div>
                  <span class=${cx('gd-state', `st-${it.state}`)}>
                    ${STATE_LABEL[it.state]}
                  </span>
                </div>
              `)}
            </div>
          `
        })}
      </div>
    </div>
  `
}
