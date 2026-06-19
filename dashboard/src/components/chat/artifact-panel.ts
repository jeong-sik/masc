// Conversation artifact/output panel — right-side inventory of every rich
// output in a keeper transcript (attachments, code, diagrams, images, SVGs,
// artifacts, tool outputs, links). Grouped by the message/turn they belong to.

import { html } from 'htm/preact'
import { useMemo, useState } from 'preact/hooks'
import type { VNode } from 'preact'
import type { ChatBlock, KeeperConversationEntry, KeeperConversationAttachment } from '../../types'
import { sanitizeHtml as purifyHtml } from '../../lib/dompurify'
import { copyToClipboard } from '../common/copyable-code'
import { showToast } from '../common/toast'

export type ArtifactKind = 'attachment' | 'code' | 'mermaid' | 'image' | 'svg' | 'artifact' | 'tool' | 'link'

export interface ArtifactItem {
  id: string
  entryId: string
  turnIndex: number
  kind: ArtifactKind
  name: string
  typeLabel: string
  size?: string
  src?: string
  data?: string
  mimeType?: string
  source?: string
  url?: string
  note?: string
}

export interface ArtifactGroup {
  entryId: string
  turnIndex: number
  label: string
  role: string
  items: ArtifactItem[]
}

function formatAttachmentSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B'
  if (bytes < 1024) return `${Math.round(bytes)} B`
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

function artifactIcon(kind: ArtifactKind): string {
  switch (kind) {
    case 'attachment': return '◫'
    case 'code': return '</>'
    case 'mermaid': return '~>'
    case 'image': return '▣'
    case 'svg': return '◫'
    case 'artifact': return '⎙'
    case 'tool': return 'T'
    case 'link': return '↗'
  }
}

function attachmentToArtifact(att: KeeperConversationAttachment, entryId: string, turnIndex: number, index: number): ArtifactItem {
  return {
    id: `${entryId}-att-${index}`,
    entryId,
    turnIndex,
    kind: 'attachment',
    name: att.name,
    typeLabel: att.mimeType,
    size: formatAttachmentSize(att.size),
    src: att.data,
    data: att.data,
    mimeType: att.mimeType,
  }
}

function blockToArtifacts(block: ChatBlock, entryId: string, turnIndex: number, blockIndex: number): ArtifactItem[] {
  switch (block.t) {
    case 'attach':
      return [{
        id: `${entryId}-block-attach-${blockIndex}`,
        entryId,
        turnIndex,
        kind: 'attachment',
        name: block.name,
        typeLabel: block.mimeType || 'file',
        size: block.size,
        src: block.src || block.data,
        data: block.data,
        mimeType: block.mimeType,
      }]
    case 'code':
      return [{
        id: `${entryId}-block-code-${blockIndex}`,
        entryId,
        turnIndex,
        kind: 'code',
        name: block.cap || `snippet-${blockIndex}`,
        typeLabel: block.cap || 'code',
        source: block.html,
      }]
    case 'mermaid':
      return [{
        id: `${entryId}-block-mermaid-${blockIndex}`,
        entryId,
        turnIndex,
        kind: 'mermaid',
        name: block.caption || 'diagram',
        typeLabel: 'mermaid',
        source: block.source,
      }]
    case 'image':
      return [{
        id: `${entryId}-block-image-${blockIndex}`,
        entryId,
        turnIndex,
        kind: 'image',
        name: block.cap || 'image',
        typeLabel: 'image',
        src: block.src,
      }]
    case 'svg':
      return [{
        id: `${entryId}-block-svg-${blockIndex}`,
        entryId,
        turnIndex,
        kind: 'svg',
        name: block.cap || 'svg',
        typeLabel: 'svg',
        source: block.svg,
      }]
    case 'artifact':
      return [{
        id: `${entryId}-block-artifact-${blockIndex}`,
        entryId,
        turnIndex,
        kind: 'artifact',
        name: block.name,
        typeLabel: block.kind || 'file',
        size: block.size,
        note: block.note,
      }]
    case 'trace':
      return block.trace.flatMap((step, stepIndex) => {
        if (step.kind !== 'tool') return []
        return [{
          id: `${entryId}-block-trace-${blockIndex}-${stepIndex}`,
          entryId,
          turnIndex,
          kind: 'tool',
          name: step.name,
          typeLabel: 'tool',
          source: step.result ?? JSON.stringify(step.args),
        }]
      })
    case 'link':
      return [{
        id: `${entryId}-block-link-${blockIndex}`,
        entryId,
        turnIndex,
        kind: 'link',
        name: block.title,
        typeLabel: block.meta || 'link',
        url: block.url,
      }]
    default:
      return []
  }
}

/** Scan conversation entries and group every artifact/output by its turn. */
export function extractArtifactGroups(entries: KeeperConversationEntry[]): ArtifactGroup[] {
  const groups: ArtifactGroup[] = []
  entries.forEach((entry, turnIndex) => {
    const items: ArtifactItem[] = []
    entry.attachments?.forEach((att, i) => { items.push(attachmentToArtifact(att, entry.id, turnIndex, i)) })
    entry.blocks?.forEach((block, i) => { items.push(...blockToArtifacts(block, entry.id, turnIndex, i)) })
    if (items.length === 0) return
    groups.push({
      entryId: entry.id,
      turnIndex,
      label: entry.label || entry.role,
      role: entry.role,
      items,
    })
  })
  return groups
}

function hasDownloadPayload(item: ArtifactItem): boolean {
  if (item.kind === 'link') return false
  return !!(item.data || item.src || item.source)
}

function downloadPayload(item: ArtifactItem): void {
  if (item.kind === 'link') return
  const content = item.data || item.src || item.source || ''
  const mime = item.mimeType || 'text/plain'
  const filename = item.name
  let url: string
  if (content.startsWith('data:')) {
    url = content
  } else {
    const blob = new Blob([content], { type: mime })
    url = URL.createObjectURL(blob)
  }
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  if (!content.startsWith('data:')) URL.revokeObjectURL(url)
}

function sanitizeHtml(raw: string): string {
  return purifyHtml(raw)
}

function ArtifactPreview({ item }: { item: ArtifactItem }): VNode {
  switch (item.kind) {
    case 'image':
      return html`
        <div class="chat-artifact-preview" data-artifact-preview="image">
          ${item.src
            ? html`<img src=${item.src} alt=${item.name} class="chat-artifact-preview-img" />`
            : html`<div class="chat-artifact-preview-ph">이미지 없음</div>`}
        </div>
      `
    case 'svg':
      return html`
        <div
          class="chat-artifact-preview"
          data-artifact-preview="svg"
          dangerouslySetInnerHTML=${{ __html: item.source ? sanitizeHtml(item.source) : '' }}
        />
      `
    case 'link':
      return html`
        <div class="chat-artifact-preview" data-artifact-preview="link">
          <a
            class="chat-artifact-preview-link"
            href=${item.url}
            target="_blank"
            rel="noopener noreferrer"
          >
            <span>${item.name}</span>
            <span class="chat-artifact-preview-link-meta">${item.url}</span>
          </a>
        </div>
      `
    case 'attachment':
      if (item.mimeType?.startsWith('image/') && item.src) {
        return html`
          <div class="chat-artifact-preview" data-artifact-preview="attachment-image">
            <img src=${item.src} alt=${item.name} class="chat-artifact-preview-img" />
          </div>
        `
      }
      return html`
        <div class="chat-artifact-preview" data-artifact-preview="attachment">
          <pre class="chat-artifact-preview-text">${item.name}</pre>
        </div>
      `
    default:
      return html`
        <div class="chat-artifact-preview" data-artifact-preview="code">
          <pre class="chat-artifact-preview-text"><code dangerouslySetInnerHTML=${{ __html: item.source ? sanitizeHtml(item.source) : '' }} /></pre>
        </div>
      `
  }
}

function ArtifactCard({ item }: { item: ArtifactItem }): VNode {
  const [open, setOpen] = useState(false)
  const [copying, setCopying] = useState(false)
  const canDownload = hasDownloadPayload(item)
  const canOpen = item.kind === 'link' ? !!item.url : true

  const handleOpen = () => {
    if (item.kind === 'link' && item.url) {
      window.open(item.url, '_blank', 'noopener,noreferrer')
      return
    }
    setOpen((o) => !o)
  }

  const handleDownload = () => {
    if (!canDownload) return
    downloadPayload(item)
  }

  const handleCopy = async () => {
    const text = item.data || item.src || item.source || item.url || ''
    if (!text) return
    const ok = await copyToClipboard(text)
    if (ok) {
      setCopying(true)
      showToast('클립보드에 복사됨', 'success', 1400)
      setTimeout(() => setCopying(false), 1200)
    } else {
      showToast('복사 실패', 'error')
    }
  }

  const meta = [item.typeLabel.toUpperCase(), item.size, item.note].filter(Boolean).join(' · ')

  return html`
    <div class="chat-artifact-card" data-artifact-kind=${item.kind} data-artifact-id=${item.id}>
      <div class="chat-artifact-card-hd">
        <span class="chat-artifact-card-icon">${artifactIcon(item.kind)}</span>
        <div class="chat-artifact-card-info">
          <div class="chat-artifact-card-name" title=${item.name}>${item.name}</div>
          <div class="chat-artifact-card-meta">${meta}</div>
        </div>
      </div>
      <div class="chat-artifact-card-actions">
        <button
          type="button"
          class="chat-artifact-card-btn"
          disabled=${!canOpen}
          onClick=${handleOpen}
          aria-label=${item.kind === 'link' ? '링크 열기' : '미리보기'}
        >
          ${item.kind === 'link' ? '열기' : open ? '닫기' : '열기'}
        </button>
        <button
          type="button"
          class="chat-artifact-card-btn"
          disabled=${!canDownload}
          onClick=${handleDownload}
          aria-label="다운로드"
        >
          다운로드
        </button>
        <button
          type="button"
          class="chat-artifact-card-btn ${copying ? 'copied' : ''}"
          onClick=${handleCopy}
          aria-label="복사"
        >
          ${copying ? '✓' : '복사'}
        </button>
      </div>
      ${open ? html`<${ArtifactPreview} item=${item} />` : null}
    </div>
  `
}

/** Right-side panel that inventories every artifact/output in the transcript. */
export function ChatArtifactPanel({ entries }: { entries: KeeperConversationEntry[] }): VNode {
  const groups = useMemo(() => extractArtifactGroups(entries), [entries])
  const total = useMemo(() => groups.reduce((sum, g) => sum + g.items.length, 0), [groups])

  return html`
    <aside class="chat-artifact-panel" role="complementary" aria-label="대화 아티팩트">
      <div class="chat-artifact-panel-head">
        <span class="chat-artifact-panel-title">⚡ 아티팩트</span>
        <span class="chat-artifact-panel-count">${total}</span>
      </div>
      ${groups.length === 0
        ? html`<div class="chat-artifact-panel-empty">이 대화에는 아티팩트가 없습니다.</div>`
        : html`
            <div class="chat-artifact-panel-body">
              ${groups.map((group) => html`
                <div key=${group.entryId} class="chat-artifact-group" data-artifact-group=${group.entryId}>
                  <div class="chat-artifact-group-hd">
                    <span class="chat-artifact-group-turn">#${group.turnIndex + 1}</span>
                    <span class="chat-artifact-group-role ${group.role}">${group.label}</span>
                  </div>
                  <div class="chat-artifact-group-items">
                    ${group.items.map((item) => html`<${ArtifactCard} key=${item.id} item=${item} />`)}
                  </div>
                </div>
              `)}
            </div>
          `}
    </aside>
  `
}
