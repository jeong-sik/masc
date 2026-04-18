// ConnectorPathsStrip — collapsible disclosure panel that answers the
// "where is my config?" question in one glance.
//
// Operators repeatedly ask "where does this keeper's TOML live?" or
// "where is the sidecar log?" and today the only answer is a code tour
// or Slack. This strip surfaces four MASC-managed paths directly:
//
//   - Connectors dir : {mascRoot}/connectors/ — sidecar names.json /
//                      status.json; derived from an observed connector's
//                      `names_path` if available
//   - Logs dir       : {mascRoot}/logs/       — sidecar log directory
//   - Keepers dir    : config/keepers/         — keeper TOML (repo-relative)
//   - Sidecars dir   : sidecars/               — sidecar run.sh scripts
//                                                (repo-relative)
//
// The top two are derived from runtime; the bottom two are repo-relative
// conventions and always shown. Collapsed by default so the main overview
// strip stays dense.

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import type { GateConnectorInfo } from '../api/gate'
import { CopyableCode } from './common/copyable-code'

const pathsExpanded = signal<boolean>(false)

export function _testResetPathsStrip() {
  pathsExpanded.value = false
}

export interface MascPaths {
  connectorsDir: string | null
  logsDir: string | null
  keepersDir: string
  sidecarsDir: string
}

/** Pure: derive MASC-managed paths from the first connector whose
    runtime has been observed (has a `names_path`). Returns `null` for
    dynamic fields when no runtime data yet. Repo-relative conventions
    (keepers/, sidecars/) are never null — they're stable regardless of
    runtime state. Cold-start / pre-runtime view still gets useful
    paths for the static half. */
export function deriveMascPaths(connectors: GateConnectorInfo[]): MascPaths {
  const fallback: MascPaths = {
    connectorsDir: null,
    logsDir: null,
    keepersDir: 'config/keepers/',
    sidecarsDir: 'sidecars/',
  }
  const withPath = connectors.find(
    c => typeof c.names_path === 'string' && c.names_path.length > 0,
  )
  if (!withPath) return fallback
  const match = withPath.names_path.match(/^(.*)\/connectors\/[^/]+\/names\.json$/)
  if (!match) return fallback
  const mascRoot = match[1] ?? ''
  return {
    connectorsDir: `${mascRoot}/connectors/`,
    logsDir: `${mascRoot}/logs/`,
    keepersDir: 'config/keepers/',
    sidecarsDir: 'sidecars/',
  }
}

function PathRow({ label, value, hint }: { label: string; value: string; hint: string }) {
  return html`
    <div class="flex items-center gap-2" data-paths-row=${label}>
      <span
        class="w-25 shrink-0 text-3xs uppercase tracking-4 text-[var(--text-dim)]"
        title=${hint}
      >${label}</span>
      <div class="min-w-0 flex-1">
        <${CopyableCode} command=${value} ariaLabel=${`Copy ${label} path`} />
      </div>
    </div>
  `
}

export function ConnectorPathsStrip({ connectors }: { connectors: GateConnectorInfo[] }) {
  const paths = deriveMascPaths(connectors)
  const open = pathsExpanded.value
  return html`
    <div
      class="mb-3 rounded border border-[var(--card-border)] bg-[var(--bg-1)]"
      data-panel="connector-paths-strip"
    >
      <button
        type="button"
        class="flex w-full cursor-pointer items-center justify-between gap-3 px-3 py-2 text-left text-2xs text-[var(--text-dim)] hover:text-[var(--text-body)]"
        onClick=${() => { pathsExpanded.value = !open }}
        aria-expanded=${open}
        aria-controls="connector-paths-body"
      >
        <span>
          <span class="mr-2 text-3xs uppercase tracking-4">Paths</span>
          <span class="font-mono">${paths.connectorsDir ?? paths.sidecarsDir}</span>
          <span class="ml-2 text-[var(--text-dim)]">${paths.connectorsDir ? '' : '(런타임 미관찰 · sidecar 경로만 표시)'}</span>
        </span>
        <span>${open ? '▴' : '▾'}</span>
      </button>
      ${open
        ? html`
            <div id="connector-paths-body" class="space-y-1.5 border-t border-[var(--card-border)] px-3 py-2">
              ${paths.connectorsDir
                ? html`<${PathRow} label="Connectors" value=${paths.connectorsDir} hint="sidecar names.json / status.json 위치" />`
                : null}
              ${paths.logsDir
                ? html`<${PathRow} label="Logs" value=${paths.logsDir} hint="sidecar 로그 디렉토리" />`
                : null}
              <${PathRow} label="Keepers" value=${paths.keepersDir} hint="keeper TOML 설정 파일" />
              <${PathRow} label="Sidecars" value=${paths.sidecarsDir} hint="sidecar 스크립트 (run.sh) 위치" />
            </div>
          `
        : null}
    </div>
  `
}
