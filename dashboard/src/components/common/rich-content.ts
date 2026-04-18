import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import { Markdown } from './markdown'
import { fetchLinkPreviews, type LinkPreview } from '../../api/link-previews'
import { prepareRichContent } from './rich-content-utils'

function previewCard(preview: LinkPreview) {
  const href = preview.canonical_url || preview.url
  const title = preview.title || preview.site_name || preview.url
  const description = preview.description || ''
  const imageUrl = preview.image_url || null
  const faviconUrl = preview.favicon_url || null
  const hostLabel = (() => {
    try {
      return new URL(href).hostname
    } catch {
      return preview.site_name || preview.url
    }
  })()

  return html`
    <a
      key=${preview.url}
      href=${href}
      target="_blank"
      rel="noreferrer"
      class="group flex overflow-hidden rounded border border-[var(--card-border)] bg-[var(--white-3)] text-inherit no-underline transition-colors hover:border-[var(--accent-20)] hover:bg-[var(--white-5)]"
    >
      ${imageUrl
        ? html`
            <div class="w-[112px] shrink-0 bg-[var(--white-5)]">
              <img src=${imageUrl} alt=${title} class="block h-full w-full object-cover" loading="lazy" />
            </div>
          `
        : null}
      <div class="min-w-0 flex-1 px-3 py-2.5">
        <div class="flex items-center gap-2 text-2xs text-[var(--text-muted)]">
          ${faviconUrl ? html`<img src=${faviconUrl} alt="" class="h-3.5 w-3.5 rounded-sm" loading="lazy" />` : null}
          <span class="truncate">${preview.site_name || hostLabel}</span>
        </div>
        <div class="mt-1 text-xs font-semibold leading-snug text-[var(--text-strong)] group-hover:text-[var(--accent)]">
          ${title}
        </div>
        ${description
          ? html`<div class="mt-1 line-clamp-3 text-2xs leading-relaxed text-[var(--text-muted)]">${description}</div>`
          : null}
      </div>
    </a>
  `
}

export function RichContent({
  text,
  class: className,
  previewLimit = 4,
}: {
  text: string
  class?: string
  previewLimit?: number
}) {
  const prepared = useMemo(() => prepareRichContent(text, previewLimit), [text, previewLimit])
  const [previews, setPreviews] = useState<Record<string, LinkPreview>>({})

  useEffect(() => {
    let cancelled = false
    if (prepared.previewUrls.length === 0) {
      setPreviews({})
      return
    }
    void fetchLinkPreviews(prepared.previewUrls)
      .then(next => { if (!cancelled) setPreviews(next) })
      .catch(() => { if (!cancelled) setPreviews({}) })
    return () => { cancelled = true }
  }, [prepared.previewUrls.join('|')])

  if (!text) return null

  const cards = prepared.previewUrls
    .map(url => previews[url])
    .filter((preview): preview is LinkPreview => Boolean(preview))

  return html`
    <div class="flex flex-col gap-3">
      <${Markdown} text=${prepared.markdownText} class=${className} />
      ${cards.length > 0
        ? html`<div class="grid gap-2">${cards.map(card => previewCard(card))}</div>`
        : null}
    </div>
  `
}
