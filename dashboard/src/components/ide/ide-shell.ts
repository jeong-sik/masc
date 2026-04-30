import { html } from 'htm/preact'

// PR-1 placeholder: route + navigation entry are wired but the actual
// 4-pane content (EXPLORER · 에디터 · CONVERSATION · ACTIVITY) lands in
// PR-2. The shell renders the cockpit IdePlane prototype's grid stub
// (`design-system/ui_kits/cockpit/Planes.jsx:144`) so the production
// surface picks up where v0.4 SSOT left off.
//
// Audit reference:
//   dashboard/design-system/audits/2026-04-30-ide-mockup-vs-v0.4-mapping.md
//
// All visible color and spacing values flow from v0.4 Semantic tier
// tokens; do not introduce raw hex literals here.

export function IdeShell() {
  return html`
    <section
      class="ide-plane-shell"
      role="region"
      aria-label="Code IDE shell (Phase 1 placeholder)"
      style=${{
        display: 'grid',
        gridTemplateRows: 'auto 1fr',
        gap: 'var(--sp-3)',
        padding: 'var(--sp-4)',
        minHeight: 'calc(100vh - var(--h-topbar) - var(--h-kpi))',
        background: 'var(--color-bg-page)',
        color: 'var(--color-fg-primary)',
      }}
    >
      <header style=${{ display: 'flex', flexDirection: 'column', gap: 'var(--sp-1)' }}>
        <h1 style=${{ font: 'var(--type-section-title)', margin: 0 }}>
          코드 IDE
        </h1>
        <p style=${{ color: 'var(--color-fg-muted)', margin: 0, font: 'var(--type-body)' }}>
          Multi-keeper 협업 코드 review surface — Phase 1 라우트 셋업.
          EXPLORER · 에디터 · CONVERSATION · ACTIVITY 4-pane 콘텐츠는 후속 PR에서 채워집니다.
        </p>
      </header>
      <div
        class="ide-plane-grid-placeholder"
        role="presentation"
        style=${{
          display: 'grid',
          gridTemplateColumns: 'minmax(180px, 240px) minmax(0, 1fr) minmax(280px, 320px)',
          gridTemplateRows: '1fr',
          gap: 'var(--sp-3)',
          minHeight: 0,
        }}
      >
        ${PanePlaceholder({ title: 'EXPLORER', body: '파일 트리 (PR-2 / PR-4)' })}
        ${PanePlaceholder({ title: '에디터', body: '코드 + blame-by-keeper (PR-2 / PR-5)' })}
        ${PanePlaceholder({
          title: 'CONVERSATION · ACTIVITY',
          body: '라인 anchored thread + activity 스트림 (PR-2 / PR-6)',
        })}
      </div>
    </section>
  `
}

function PanePlaceholder({ title, body }: { title: string; body: string }) {
  return html`
    <div
      style=${{
        display: 'flex',
        flexDirection: 'column',
        gap: 'var(--sp-2)',
        padding: 'var(--sp-3)',
        background: 'var(--color-bg-surface)',
        border: '1px solid var(--color-border-default)',
        borderRadius: 'var(--r-2)',
      }}
    >
      <span style=${{ color: 'var(--color-fg-muted)', font: 'var(--type-eyebrow)' }}>
        ${title}
      </span>
      <span style=${{ color: 'var(--color-fg-secondary)', font: 'var(--type-body)' }}>
        ${body}
      </span>
    </div>
  `
}
