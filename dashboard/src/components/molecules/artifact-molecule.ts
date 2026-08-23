// keeper-v2 design artifact molecule — Artifact from
// prototypes/keeper-v2/molecules.jsx, fed by the live ChatArtifactBlock
// (src/types/core.ts). Download is real (the block carries a data: payload);
// "열기" only renders when the host provides an onOpen handler, so the button
// never promises a preview the surface cannot show.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import type { ChatArtifactBlock } from '../../types'

function artifactIcon(kind?: string): string {
  if (kind === 'md') return '⌹'
  if (kind === 'svg') return '◫'
  if (kind === 'json') return '{ }'
  return '⎙'
}

// Same payload rules as chat/primitives.ts downloadArtifact: data: URLs are
// opened directly, everything else goes through a blob.
function downloadArtifactPayload(data: string, filename: string, mimeType?: string): void {
  let url = data
  let revoke = false
  if (!data.startsWith('data:')) {
    url = URL.createObjectURL(new Blob([data], { type: mimeType || 'text/plain' }))
    revoke = true
  }
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  if (revoke) URL.revokeObjectURL(url)
}

export function MoleculeArtifact({
  kind,
  name,
  size,
  note,
  data,
  mimeType,
  onOpen,
}: ChatArtifactBlock & { onOpen?: () => void }): VNode {
  const sub = [(kind || 'file').toUpperCase(), size, note].filter(Boolean).join(' · ')
  return html`
    <div class="artifact">
      <div class="af-ico">${artifactIcon(kind)}</div>
      <div class="af-meta">
        <div class="af-name mono">${name}</div>
        <div class="af-sub">${sub}</div>
      </div>
      ${onOpen
        ? html`<button type="button" class="af-btn" onClick=${onOpen}>열기</button>`
        : null}
      <button
        type="button"
        class="af-btn"
        disabled=${!data}
        onClick=${() => { if (data) downloadArtifactPayload(data, name, mimeType) }}
      >
        다운로드
      </button>
    </div>
  `
}
