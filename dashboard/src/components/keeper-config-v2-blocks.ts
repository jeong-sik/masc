// Keeper config panel — keeper-v2 design blocks (prototypes/keeper-v2/keeper-config.jsx parity).
//
// Two blocks the panel actually mounts:
//   - kcf-plan badge: the design's own marker for a field that is planned but
//     has no backend control, so the panel says so instead of faking a toggle.
//   - avatar preview: slot/sigil come from the SAME deterministic kSlot/kSigil
//     derivation KeeperBadge uses, so the preview always matches the roster.
//     Portrait picker / slot-color / sigil editing have no keeper avatar API.
//
// The runtime picker, goals browser, guard list, intervention list and tool
// catalog blocks were written against the same prototype but the panel never
// mounted them; they were removed rather than left as a second, drifting copy
// of surfaces the panel already renders its own way.

import { html } from 'htm/preact'
import { kSigil, kSlot } from './keeper-badge'

// ── shared badges ────────────────────────────────────────

// The design's own marker for fields that are planned but not yet implemented.
export function KcfPlan({ children }: { children?: unknown }) {
  return html`<span class="kcf-plan" title="아직 미구현 — 기획 단계">기획${children ? html`<em>${children}</em>` : null}</span>`
}

export function KcfAvatarBlock({ keeperName, displayName }: { keeperName: string; displayName: string }) {
  const slot = kSlot(keeperName)
  const sigil = kSigil(keeperName)
  return html`
    <div class="kav">
      <div class="kav-preview">
        <span class="kav-face is-sigil" style=${`background: var(--kp${slot})`}>${sigil}</span>
        <div class="kav-preview-meta">
          <span class="kav-preview-name">${displayName}</span>
          <span class="kav-preview-mode mono">시길 · slot ${slot} · ${sigil}</span>
        </div>
      </div>

      <div class="kav-block">
        <label class="kav-lbl">아바타 소스</label>
        <div class="kav-src">
          <button type="button" class="kav-src-b on" disabled title="시길 — keeper id 에서 결정론적으로 파생됩니다">◈ 시길</button>
          <button type="button" class="kav-src-b" disabled title="초상화 프리셋·업로드는 keeper avatar API 가 없어 기획 단계입니다">◉ 초상화 <${KcfPlan} /></button>
        </div>
      </div>

      <div class="kav-block">
        <label class="kav-lbl">초상화 <span class="kav-lbl-hint">프리셋·업로드 <${KcfPlan} /></span></label>
        <div class="kav-portraits">
          <button
            type="button"
            class="kav-por kav-upload"
            disabled
            title="초상화 프리셋·업로드는 keeper avatar API 가 없어 기획 단계입니다"
          >
            <span class="kav-upload-ic">＋<em>업로드</em></span>
          </button>
        </div>
      </div>

      <div class="kav-block">
        <label class="kav-lbl">슬롯 색 <span class="kav-lbl-hint">시길·칩·강조색 전반에 적용 · id 해시로 결정</span></label>
        <div class="kav-swatches">
          ${Array.from({ length: 12 }, (_, i) => i + 1).map(n => html`
            <button
              key=${n}
              type="button"
              class=${`kav-sw ${slot === n ? 'on' : ''}`}
              style=${`--sw: var(--kp${n})`}
              disabled
              title=${`slot ${n} — keeper id 해시로 결정됩니다`}
            >
              ${slot === n ? html`<span class="kav-sw-tick">✓</span>` : null}
            </button>
          `)}
        </div>
      </div>

      <div class="kav-block kav-block-row">
        <div>
          <label class="kav-lbl">시길 <span class="kav-lbl-hint">2글자 모노그램 · id 에서 파생</span></label>
          <input
            class="kav-sigil-in mono"
            maxLength=${2}
            value=${sigil}
            readOnly
            aria-label="시길"
            title="keeper id 에서 파생 — 편집은 기획 단계"
          />
        </div>
        <span class="kav-sigil-prev mono" style=${`background: var(--kp${slot})`}>${sigil}</span>
      </div>
    </div>
  `
}

// ── 런타임 picker (runtime tab) ──────────────────────────
// The design picks from the full runtime.toml catalog with a search box; the
// live catalog is /api/v1/providers. where/badges are derived only from real
// snapshot fields (endpoint_url, capability flags) — never invented.
