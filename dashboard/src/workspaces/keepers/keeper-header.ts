/**
 * Right Keeper Header Hero (48px portrait.png + Candle Brass 14% halo + lifecycle controls + 5 entity tabs).
 */

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { activeWorkspaceId } from '../../core/auth'
import { formatObserved } from '../../core/resource-cache'
import { useAuthenticatedPortrait } from '../../lib/portrait-cache'
import { keeperPortraitUrl, kSigil } from '../../components/keeper-badge'
import { TargetLockedAction } from '../../components/primitives/target-locked-action'
import {
  bootKeeperAction,
  deleteKeeperAction,
  interruptKeeperTurnAction,
  needsRosterAttention,
  observeRosterContextPct,
  pauseKeeperAction,
  resumeKeeperAction,
} from './keepers-api'
import {
  KEEPER_ENTITY_TAB_LABELS,
  KEEPER_ENTITY_TABS,
  type KeeperEntityTab,
} from '../../routes/router'
import type { KeeperRosterItem } from './types'

export interface KeeperHeaderProps {
  readonly keeper: KeeperRosterItem
  readonly activeTab: KeeperEntityTab
  readonly onSelectTab: (tab: KeeperEntityTab) => void
  readonly onLifecycleMutated: () => void
  readonly onDeleted: () => void
}

const PURGE_ARTIFACTS: readonly string[] = [
  '메트릭·결정·상태 전이 로그',
  'Memory OS 스냅샷과 저널',
  'TOML 설정 및 대화 기록',
  '격리 작업 디렉터리 및 토큰',
]

export function KeeperHeader(props: KeeperHeaderProps) {
  const { keeper } = props
  const rawPortraitUrl = keeperPortraitUrl(keeper.name, 96)
  const authenticatedPortraitSrc = useAuthenticatedPortrait(rawPortraitUrl)
  const [failedSrc, setFailedSrc] = useState<string | null>(null)
  const [busyAction, setBusyAction] = useState<string | null>(null)
  const [statusMessage, setStatusMessage] = useState<{ readonly tone: 'ok' | 'bad'; readonly text: string } | null>(null)
  const [deleteOpen, setDeleteOpen] = useState(false)
  const [deleteConfirmName, setDeleteConfirmName] = useState('')

  const ctxObs = observeRosterContextPct(keeper)
  const ctxText = formatObserved(ctxObs, (v) => `${v}%`)
  const failing = needsRosterAttention(keeper)

  const runLifecycle = async (
    label: string,
    fn: () => Promise<{ ok: boolean; error?: { message: string } }>,
  ) => {
    setBusyAction(label)
    setStatusMessage(null)
    const res = await fn()
    setBusyAction(null)
    if (!res.ok) {
      setStatusMessage({ tone: 'bad', text: `${label} 실패: ${res.error?.message ?? '오류'}` })
      return
    }
    setStatusMessage({ tone: 'ok', text: `${label} 요청이 처리되었습니다.` })
    props.onLifecycleMutated()
  }

  const handleConfirmDelete = async () => {
    if (deleteConfirmName.trim() !== keeper.name) return
    setBusyAction('delete')
    const res = await deleteKeeperAction(keeper.name)
    setBusyAction(null)
    if (!res.ok) {
      setStatusMessage({ tone: 'bad', text: `삭제 실패: ${res.error.message}` })
      return
    }
    setDeleteOpen(false)
    setDeleteConfirmName('')
    props.onDeleted()
  }

  return html`
    <header class="kp-hero">
      <div class="kp-hero-top">
        <div class="kp-hero-id">
          <div class="kp-hero-portrait-ring">
            ${authenticatedPortraitSrc !== null && failedSrc !== authenticatedPortraitSrc
              ? html`
                  <img
                    class="kp-hero-portrait-img"
                    src=${authenticatedPortraitSrc}
                    data-portrait-url=${rawPortraitUrl}
                    alt=${`${keeper.name} portrait`}
                    onError=${() => setFailedSrc(authenticatedPortraitSrc)}
                  />
                `
              : html`
                  <span class="kp-hero-portrait-sigil" aria-label=${keeper.name}>
                    ${kSigil(keeper.name)}
                  </span>
                `}
          </div>

          <div class="kp-hero-text">
            <h1 class="kp-hero-name">${keeper.name}</h1>
            <div class="kp-pill-row">
              <span class="kp-pill" data-tone=${failing ? 'bad' : keeper.paused ? 'warn' : 'ok'}>
                ${failing ? `⚠ ${keeper.health}` : keeper.paused ? 'Paused' : keeper.health}
              </span>
              <span class="kp-pill" data-tone="info">${keeper.phase}</span>
              <span class="kp-pill">${keeper.runtime_id}</span>
              <span class="kp-pill" data-tone=${ctxObs.kind === 'value' && ctxObs.data >= 80 ? 'warn' : 'brass'}>
                Ctx ${ctxText}
              </span>
              ${keeper.active_turn && html`
                <span class="kp-pill" data-tone="brass">
                  ● Turn (${keeper.active_turn.lane})
                </span>
              `}
            </div>
          </div>
        </div>

        <div class="kp-lifecycle-bar" role="group" aria-label="Keeper 수명주기 제어">
          <button
            type="button"
            class="btn-ghost"
            disabled=${busyAction !== null}
            onClick=${() => void runLifecycle('Boot', () => bootKeeperAction(keeper.name))}
          >
            Boot
          </button>
          ${keeper.paused
            ? html`
                <button
                  type="button"
                  class="btn-primary"
                  disabled=${busyAction !== null}
                  onClick=${() => void runLifecycle('Resume', () => resumeKeeperAction(keeper.name))}
                >
                  Resume
                </button>
              `
            : html`
                <button
                  type="button"
                  class="btn-ghost"
                  disabled=${busyAction !== null}
                  onClick=${() => void runLifecycle('Pause', () => pauseKeeperAction(keeper.name))}
                >
                  Pause
                </button>
              `}
          <button
            type="button"
            class="btn-ghost"
            disabled=${busyAction !== null}
            onClick=${() => void runLifecycle('Interrupt Turn', () => interruptKeeperTurnAction(keeper.name))}
          >
            Interrupt Turn
          </button>
          <button
            type="button"
            class="kp-btn-danger"
            disabled=${busyAction !== null}
            onClick=${() => setDeleteOpen(true)}
          >
            Delete
          </button>
        </div>
      </div>

      ${statusMessage && html`
        <div
          class=${statusMessage.tone === 'bad' ? 'ap-error' : 'kp-pill'}
          data-tone=${statusMessage.tone}
          role="status"
        >
          ${statusMessage.text}
        </div>
      `}

      <nav class="kp-tabs" role="tablist" aria-label="Keeper 상세 탭">
        ${KEEPER_ENTITY_TABS.map((tab) => html`
          <button
            key=${tab}
            type="button"
            role="tab"
            class="kp-tab"
            aria-selected=${props.activeTab === tab ? 'true' : 'false'}
            onClick=${() => props.onSelectTab(tab)}
          >
            ${KEEPER_ENTITY_TAB_LABELS[tab]}
          </button>
        `)}
      </nav>

      ${deleteOpen && html`
        <div class="kp-modal-backdrop" role="dialog" aria-modal="true" aria-label="Keeper 영구 삭제 확인">
          <div class="kp-modal">
            <div class="kp-card-head">
              <h3>Keeper 영구 삭제: ${keeper.name}</h3>
              <button type="button" class="btn-ghost" onClick=${() => setDeleteOpen(false)}>취소</button>
            </div>
            <p class="ov-sub">다음 아티팩트가 영구 제거됩니다:</p>
            <ul>
              ${PURGE_ARTIFACTS.map((item) => html`<li key=${item}>${item}</li>`)}
            </ul>
            <${TargetLockedAction}
              target=${{
                workspaceId: activeWorkspaceId.value,
                keeper: keeper.name,
                requestId: `purge:${keeper.name}`,
                revision: keeper.phase,
              }}
            >
              <input
                type="text"
                class="kp-input"
                placeholder=${`확인하려면 "${keeper.name}" 입력`}
                aria-label="삭제 확인 Keeper 이름"
                value=${deleteConfirmName}
                onInput=${(e: Event) => setDeleteConfirmName((e.currentTarget as HTMLInputElement).value)}
              />
              <button
                type="button"
                class="kp-btn-danger"
                disabled=${deleteConfirmName.trim() !== keeper.name || busyAction !== null}
                onClick=${() => void handleConfirmDelete()}
              >
                영구 삭제 실행
              </button>
            <//>
          </div>
        </div>
      `}
    </header>
  `
}
