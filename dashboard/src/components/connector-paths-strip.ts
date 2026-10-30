// Connector configuration conventions; config-root is resolved by the server.
import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { CopyableCode } from './common/copyable-code'
import { SurfaceCard } from './common/card'

const pathsExpanded = signal<boolean>(false)

export function _testResetPathsStrip() {
  pathsExpanded.value = false
}

export interface MascPaths {
  keepersDir: string
  runtimeConfigPath: string
}

/** Repo-relative conventions. Stable regardless of runtime state, so the
    cold-start / pre-runtime view shows the same paths. */
export function deriveMascPaths(): MascPaths {
  return {
    keepersDir: '<config-root>/keepers/',
    runtimeConfigPath: '<config-root>/runtime.toml',
  }
}

function PathRow({ label, value, hint }: { label: string; value: string; hint: string }) {
  return html`
    <div class="flex items-center gap-2" data-paths-row=${label}>
      <span
        class="w-25 shrink-0 text-3xs uppercase tracking-4 text-[var(--color-fg-disabled)]"
        title=${hint}
      >${label}</span>
      <div class="min-w-0 flex-1">
        <${CopyableCode} command=${value} ariaLabel=${`Copy ${label} path`} />
      </div>
    </div>
  `
}

export function ConnectorPathsStrip() {
  const paths = deriveMascPaths()
  const open = pathsExpanded.value
  return html`
    <${SurfaceCard}
      class="mb-3 !border-[var(--color-border-default)] !bg-[var(--color-bg-surface)] v2-connector-paths-strip"
      data-panel="connector-paths-strip"
    >
      <button
        type="button"
        class="flex w-full cursor-pointer items-center justify-between gap-3 px-3 py-2 text-left text-2xs text-[var(--color-fg-disabled)] hover:text-[var(--color-fg-primary)]"
        onClick=${() => { pathsExpanded.value = !open }}
        aria-expanded=${open}
        aria-controls="connector-paths-body"
      >
        <span>
          <span class="mr-2 text-3xs uppercase tracking-4">경로</span>
          <span class="font-mono">${paths.runtimeConfigPath}</span>
        </span>
        <span>${open ? '▴' : '▾'}</span>
      </button>
      ${open
        ? html`
            <div id="connector-paths-body" class="space-y-1.5 border-t border-[var(--color-border-default)] px-3 py-2">
              <${PathRow} label="키퍼" value=${paths.keepersDir} hint="keeper TOML 설정 파일" />
              <${PathRow} label="서버 설정" value=${paths.runtimeConfigPath} hint="서버의 유효 config-root 아래 runtime.toml" />
            </div>
          `
        : null}
    </${SurfaceCard}>
  `
}
