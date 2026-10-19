import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { artifactHref, type ArtifactDocument } from '../../api/published-artifacts'
import { Markdown } from '../common/markdown'
import { navigate } from '../../router'
import { copyToClipboard } from '../common/copyable-code'
import { showToast } from '../common/toast'

// Opaque origin: no allow-same-origin. Keep the CSP first so the body cannot
// load subresources before the policy applies. Scripts support self-contained
// interactive reports; no dashboard token or frame messaging bridge is supplied.
export function artifactHtmlDocument(source: string): string {
  return '<!doctype html><meta charset="utf-8">'
    + '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'unsafe-inline\'; style-src \'unsafe-inline\'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src \'none\'; frame-src \'none\'; object-src \'none\'; base-uri \'none\'; form-action \'none\'">'
    + source
}

function downloadSource(doc: ArtifactDocument): void {
  const { artifact, content } = doc
  const extension = artifact.format === 'html' ? 'html' : 'md'
  // Encode first to avoid Blob's platform newline conversion.
  const blob = new Blob([new TextEncoder().encode(content)], { type: `text/${artifact.format};charset=utf-8` })
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = `${artifact.id}-v${artifact.revision}.${extension}`
  anchor.click()
  URL.revokeObjectURL(url)
}

export function ArtifactReader({ doc, fixedRevision }: { doc: ArtifactDocument; fixedRevision: boolean }) {
  const [view, setView] = useState<'rendered' | 'source'>('rendered')
  const { artifact, content, revisions } = doc
  const changeRevision = (revision: string) => navigate('workspace', {
    section: 'artifacts', artifact: artifact.id,
    ...(revision === 'latest' ? {} : { revision }),
  })
  const copyLink = async () => {
    const href = artifactHref(artifact.id, fixedRevision ? artifact.revision : undefined)
    const success = await copyToClipboard(new URL(href, window.location.href).href)
    showToast(success ? '문서 링크를 복사했습니다.' : '링크를 복사하지 못했습니다.', success ? 'success' : 'error')
  }
  return html`
    <article class="min-w-0 rounded-lg border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]" aria-label="아티팩트 본문">
      <header class="border-b border-[var(--color-border-default)] p-4 space-y-3">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <span class="text-xs uppercase tracking-wider text-[var(--color-fg-muted)]">${artifact.format} · v${artifact.revision}</span>
          <div class="flex flex-wrap gap-3 text-xs">
            <button type="button" onClick=${copyLink}>링크 복사</button>
            <button type="button" onClick=${() => downloadSource(doc)}>원본 다운로드</button>
          </div>
        </div>
        <h2 class="m-0 break-words text-xl font-semibold">${artifact.title}</h2>
        <p class="m-0 text-sm text-[var(--color-fg-secondary)]">${artifact.summary}</p>
        <div class="flex flex-wrap items-center gap-3 text-xs text-[var(--color-fg-secondary)]">
          <a href=${`#/keepers?keeper=${encodeURIComponent(artifact.author)}`}>${artifact.author}</a>
          <time dateTime=${artifact.created_at}>${new Date(artifact.created_at).toLocaleString()}</time>
          ${artifact.task_id ? html`<a href=${`#/workspace?section=planning&task=${encodeURIComponent(artifact.task_id)}`}>${artifact.task_id}</a>` : null}
          ${artifact.goal_id ? html`<a href=${`#/workspace?section=planning&goal=${encodeURIComponent(artifact.goal_id)}`}>${artifact.goal_id}</a>` : null}
        </div>
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="flex gap-3" aria-label="본문 표시 방식">
            <button type="button" aria-pressed=${view === 'rendered'} onClick=${() => setView('rendered')}>미리보기</button>
            <button type="button" aria-pressed=${view === 'source'} onClick=${() => setView('source')}>원본</button>
          </div>
          <label class="text-xs">버전 ${' '}
            <select aria-label="문서 버전" value=${fixedRevision ? String(artifact.revision) : 'latest'}
              onChange=${(event: Event) => changeRevision((event.target as HTMLSelectElement).value)}>
              <option value="latest">최신 버전</option>
              ${revisions.map(r => html`<option key=${r.revision} value=${String(r.revision)}>v${r.revision} · ${r.author} · ${new Date(r.created_at).toLocaleString()}</option>`)}
            </select>
          </label>
        </div>
      </header>
      <div class="min-w-0 p-4">
        ${view === 'source'
          ? html`<pre tabIndex=${0} aria-label="문서 원본" class="m-0 max-h-[75vh] overflow-auto whitespace-pre-wrap break-words text-xs">${content}</pre>`
          : artifact.format === 'markdown'
            ? html`<${Markdown} text=${content} />`
            : html`<iframe title=${artifact.title} sandbox="allow-scripts" referrerPolicy="no-referrer"
                class="h-[75vh] min-h-96 w-full rounded border-0 bg-white" srcDoc=${artifactHtmlDocument(content)} />`}
      </div>
    </article>
  `
}
