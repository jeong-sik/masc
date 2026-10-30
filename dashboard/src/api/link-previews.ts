import { post } from './core'
import { isRecord } from '../components/common/normalize'
import {
  safeParseLinkPreview,
  type LinkPreview,
  type LinkPreviewKind,
} from './schemas/link-previews'

export type { LinkPreview, LinkPreviewKind }

interface LinkPreviewResponse {
  previews?: Record<string, unknown>
  errors?: Record<string, unknown>
}

interface CacheEntry {
  preview: LinkPreview | null
  expiresAt: number
}

const LOCAL_PREVIEW_TTL_MS = 15 * 60 * 1000
const LOCAL_ERROR_TTL_MS = 5 * 60 * 1000
const previewCache = new Map<string, CacheEntry>()

function shouldUseCached(entry: CacheEntry | undefined): entry is CacheEntry {
  return Boolean(entry && entry.expiresAt > Date.now())
}

export async function fetchLinkPreviews(urls: string[]): Promise<Record<string, LinkPreview>> {
  const uniqueUrls = [...new Set(urls.map(url => url.trim()).filter(Boolean))].slice(0, 8)
  if (uniqueUrls.length === 0) return {}

  const result: Record<string, LinkPreview> = {}
  const missing: string[] = []

  for (const url of uniqueUrls) {
    const cached = previewCache.get(url)
    if (shouldUseCached(cached)) {
      if (cached.preview) result[url] = cached.preview
      continue
    }
    missing.push(url)
  }

  if (missing.length === 0) return result

  const raw = await post<LinkPreviewResponse>('/api/v1/dashboard/link-previews', { urls: missing })
  const previews = isRecord(raw.previews) ? raw.previews : {}
  const errors = isRecord(raw.errors) ? raw.errors : {}

  for (const url of missing) {
    const parsed = safeParseLinkPreview(previews[url])
    if (parsed.success) {
      previewCache.set(url, { preview: parsed.output, expiresAt: Date.now() + LOCAL_PREVIEW_TTL_MS })
      result[url] = parsed.output
      continue
    }

    if (errors[url] !== undefined) {
      previewCache.set(url, { preview: null, expiresAt: Date.now() + LOCAL_ERROR_TTL_MS })
    }
  }

  return result
}
