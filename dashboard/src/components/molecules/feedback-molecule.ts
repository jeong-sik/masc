// keeper-v2 design feedback & attention molecules — FeedbackRow / RegenTag /
// Noted from prototypes/keeper-v2/molecules.jsx.
//
// Live wiring status (mark, don't fake):
//   - Vote (좋음/별로) has NO backend endpoint today — the row is a controlled
//     component: a host passes value/onChange to persist, otherwise the toggle
//     is transient UI state only and nothing is recorded. Do not wire it to a
//     store that discards silently.
//   - `verified` (fbk-verify) marks a cross-verification verdict; no turn
//     payload carries that flag yet, so the chip renders only when a host
//     passes verified={true} from a real verification verdict. The tooltip
//     names no config path: it used to point at `[runtime].cross_verifier`,
//     which #29197 removed, and a chip that cites a key an operator cannot
//     find is worse than one that cites none.
//   - RegenTag: KeeperConversationEntry has no "regenerated" marker — render
//     only where a host knows a reply was regenerated.

import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { VNode } from 'preact'

export type MoleculeFeedbackValue = 'up' | 'down' | null

export function MoleculeFeedbackRow({
  value,
  onChange,
  onInspect,
  onCopy,
  onRegenerate,
  verified = false,
  showCopy = false,
  showRegen = false,
  showVote = true,
}: {
  value?: MoleculeFeedbackValue
  onChange?: (next: MoleculeFeedbackValue) => void
  onInspect?: () => void
  onCopy?: () => void
  onRegenerate?: () => void
  verified?: boolean
  showCopy?: boolean
  showRegen?: boolean
  showVote?: boolean
}): VNode {
  const controlled = onChange != null
  const [internal, setInternal] = useState<MoleculeFeedbackValue>(null)
  const v = controlled ? (value ?? null) : internal
  const [copied, setCopied] = useState(false)
  const [noted, setNoted] = useState(false)

  const set = (nv: 'up' | 'down') => {
    const next = v === nv ? null : nv
    if (controlled) onChange?.(next)
    else setInternal(next)
    if (next) {
      setNoted(true)
      setTimeout(() => setNoted(false), 2200)
    }
  }

  return html`
    <div class="fbk">
      ${showCopy
        ? html`
            <button
              type="button"
              class="fbk-btn"
              onClick=${() => {
                setCopied(true)
                setTimeout(() => setCopied(false), 1200)
                onCopy?.()
              }}
            >
              ${copied ? '✓ 복사됨' : '⎘ 복사'}
            </button>
          `
        : null}
      ${showVote
        ? html`
            <button type="button" class="fbk-btn up ${v === 'up' ? 'on' : ''}" onClick=${() => set('up')}>△ 좋음</button>
            <button type="button" class="fbk-btn down ${v === 'down' ? 'on' : ''}" onClick=${() => set('down')}>▽ 별로</button>
          `
        : null}
      ${showRegen
        ? html`<button type="button" class="fbk-btn" onClick=${onRegenerate}>↻ 재생성</button>`
        : null}
      ${onInspect
        ? html`<button type="button" class="fbk-btn inspect" onClick=${onInspect}>⊙ 턴 상세</button>`
        : null}
      ${verified
        ? html`<span
            class="fbk-verify"
            title="교차 검증 통과 — 다른 모델이 이 응답의 사실성·정합성을 확인했다"
          >◈ 검증 통과</span>`
        : null}
      ${noted ? html`<span class="fbk-noted">✓ 피드백 기록됨</span>` : null}
    </div>
  `
}

/** "재생성됨" marker on a regenerated reply. No live field marks regeneration
 *  yet — hosts render this only when they know the reply was regenerated. */
export function MoleculeRegenTag({ children = '재생성됨' }: { children?: string }): VNode {
  return html`<span class="regen-tag">${children}</span>`
}

/** Transient "기록됨 ✓" acknowledgment chip. */
export function MoleculeNoted({ children = '기록됨 ✓' }: { children?: string }): VNode {
  return html`<span class="fbk-noted">${children}</span>`
}
