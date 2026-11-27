const LEGACY_MEDIA_PREFIX = '/api/v1/media/'
const ATTACHMENT_PREFIX = '/api/v1/attachments/'
const HEX_64 = /^[0-9a-f]{64}$/
const ATTACHMENT_ID_RE = /^att_[0-9a-f]{64}$/
const RASTER_MIMES = new Set(['image/png', 'image/jpeg', 'image/jpg', 'image/gif', 'image/webp'])

export function isWorkspaceAttachmentId(value: unknown): value is string {
  return typeof value === 'string' && ATTACHMENT_ID_RE.test(value)
}

export function attachmentUrlForId(id: string): string {
  return `${ATTACHMENT_PREFIX}${encodeURIComponent(id)}`
}

export function stripPathQuery(path: string): string {
  const q = path.indexOf('?')
  return q >= 0 ? path.slice(0, q) : path
}

export function isWorkspaceAttachmentPath(value: unknown): value is string {
  if (typeof value !== 'string' || !value.startsWith(ATTACHMENT_PREFIX)) return false
  const pathname = stripPathQuery(value)
  const id = pathname.slice(ATTACHMENT_PREFIX.length)
  return isWorkspaceAttachmentId(id)
}

export function isLegacyWorkspaceMediaPath(value: unknown): value is string {
  if (typeof value !== 'string' || !value.startsWith(LEGACY_MEDIA_PREFIX)) return false
  const pathname = stripPathQuery(value)
  const token = pathname.slice(LEGACY_MEDIA_PREFIX.length)
  return token.length === 64 && HEX_64.test(token)
}

export function isWorkspaceMediaPath(value: unknown): value is string {
  return isWorkspaceAttachmentPath(value) || isLegacyWorkspaceMediaPath(value)
}

export function extractAttachmentIdFromPath(value: unknown): string | null {
  if (!isWorkspaceAttachmentPath(value)) return null
  return stripPathQuery(value).slice(ATTACHMENT_PREFIX.length)
}

export function appendAttachmentQuery(
  path: string,
  params: Readonly<Record<string, string | number | undefined | null>>,
): string {
  const entries = Object.entries(params).filter(
    (entry): entry is [string, string | number] => entry[1] !== undefined && entry[1] !== null && entry[1] !== '',
  )
  if (entries.length === 0) return path
  const qIdx = path.indexOf('?')
  const base = qIdx >= 0 ? path.slice(0, qIdx) : path
  const search = new URLSearchParams(qIdx >= 0 ? path.slice(qIdx + 1) : '')
  for (const [k, v] of entries) {
    search.set(k, String(v))
  }
  const qs = search.toString()
  return qs ? `${base}?${qs}` : base
}

export function isWorkspaceRasterMime(value: unknown): value is string {
  return typeof value === 'string' && RASTER_MIMES.has(value.toLowerCase())
}
