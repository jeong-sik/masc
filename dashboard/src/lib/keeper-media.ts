/**
 * Canonical Workspace Attachment / Legacy Media Path, Closed Raster MIME & Unified Embed Grammar SSOT.
 *
 * Unifies #55194's `/api/v1/attachments/att_<64hex>` contract with legacy `/api/v1/media/<64hex>`
 * compatibility and typed Obsidian rich embeds (`docs/rfc/RFC-workspace-media-and-rich-embed.md`):
 * - Primary attachment URI: `/api/v1/attachments/att_<64-lowercase-hex-sha256>` (optional `?max_px=...`)
 * - Legacy media URI: `/api/v1/media/<64-lowercase-hex-sha256>`
 * - Closed raster MIME union: `image/png | image/jpeg | image/gif | image/webp`
 *   (`image/svg+xml` is explicitly rejected — same-origin stored XSS vector).
 * - Unified Obsidian embed grammar:
 *   - `![[media:att_<sha256>|caption]]` / legacy `![[media:<sha256>|caption]]`
 *   - `![[wiki:<slug>]]` / `![[<slug>]]` / `![[wiki:<slug>|label]]`
 *   - `![[artifact:<id>]]` / `![[artifact:<id>|label]]`
 *   - Unknown `<scheme>:<raw>` -> `unsupported` (never coerced to wiki slug)
 *   - Malformed known scheme target -> `invalid` (never silently repaired)
 */

export const WORKSPACE_ATTACHMENT_PREFIX = '/api/v1/attachments/'
export const WORKSPACE_MEDIA_PREFIX = '/api/v1/media/'

// Matches server ceiling of Attachment_store / KeeperGeneratedMedia max bytes (50 MiB).
export const WORKSPACE_MEDIA_MAX_BYTES = 50 * 1024 * 1024

export const WORKSPACE_RASTER_MIMES = [
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
] as const

export type WorkspaceRasterMime = (typeof WORKSPACE_RASTER_MIMES)[number]

const HEX_64 = /^[0-9a-f]{64}$/
const ATTACHMENT_ID_RE = /^att_[0-9a-f]{64}$/
const WIKI_SLUG_RE = /^[a-z0-9-]+$/
const PUBLISHED_ARTIFACT_ID_RE = /^artifact-[0-9a-f]{32}$/
const RESERVED_WIKI_SLUGS = new Set(['index', 'log'])

export function isWorkspaceAttachmentId(value: unknown): value is string {
  return typeof value === 'string' && ATTACHMENT_ID_RE.test(value)
}

export function isWorkspaceMediaSha256(value: unknown): value is string {
  return typeof value === 'string' && value.length === 64 && HEX_64.test(value)
}

export function attachmentUrlForId(id: string): string {
  return `${WORKSPACE_ATTACHMENT_PREFIX}${encodeURIComponent(id)}`
}

export function stripPathQuery(path: string): string {
  const q = path.indexOf('?')
  return q >= 0 ? path.slice(0, q) : path
}

export function hasWorkspaceMediaPrefix(value: unknown): value is string {
  return (
    typeof value === 'string'
    && (value.startsWith(WORKSPACE_ATTACHMENT_PREFIX) || value.startsWith(WORKSPACE_MEDIA_PREFIX))
  )
}

export function containsWorkspaceMediaRef(text: string): boolean {
  return text.includes(WORKSPACE_ATTACHMENT_PREFIX) || text.includes(WORKSPACE_MEDIA_PREFIX)
}

export function isWorkspaceAttachmentPath(value: unknown): value is string {
  if (typeof value !== 'string' || !value.startsWith(WORKSPACE_ATTACHMENT_PREFIX)) return false
  const pathname = stripPathQuery(value)
  const id = pathname.slice(WORKSPACE_ATTACHMENT_PREFIX.length)
  return isWorkspaceAttachmentId(id)
}

export function isLegacyWorkspaceMediaPath(value: unknown): value is string {
  if (typeof value !== 'string' || !value.startsWith(WORKSPACE_MEDIA_PREFIX)) return false
  const pathname = stripPathQuery(value)
  const token = pathname.slice(WORKSPACE_MEDIA_PREFIX.length)
  return isWorkspaceMediaSha256(token) || isWorkspaceAttachmentId(token)
}

export function isWorkspaceMediaPath(value: unknown): value is string {
  return isWorkspaceAttachmentPath(value) || isLegacyWorkspaceMediaPath(value)
}

export function workspaceMediaPath(sha256: string): string | null {
  return isWorkspaceMediaSha256(sha256) ? `${WORKSPACE_MEDIA_PREFIX}${sha256}` : null
}

export function workspaceAttachmentPath(idOrSha256: string): string | null {
  if (isWorkspaceAttachmentId(idOrSha256)) return `${WORKSPACE_ATTACHMENT_PREFIX}${idOrSha256}`
  if (isWorkspaceMediaSha256(idOrSha256)) return `${WORKSPACE_ATTACHMENT_PREFIX}att_${idOrSha256}`
  return null
}

export function extractAttachmentIdFromPath(value: unknown): string | null {
  if (!isWorkspaceAttachmentPath(value)) return null
  return stripPathQuery(value).slice(WORKSPACE_ATTACHMENT_PREFIX.length)
}

export function extractWorkspaceMediaSha256(value: unknown): string | null {
  if (typeof value !== 'string') return null
  if (isWorkspaceAttachmentPath(value)) {
    const id = stripPathQuery(value).slice(WORKSPACE_ATTACHMENT_PREFIX.length)
    return id.slice(4)
  }
  if (isLegacyWorkspaceMediaPath(value)) {
    const token = stripPathQuery(value).slice(WORKSPACE_MEDIA_PREFIX.length)
    return token.startsWith('att_') ? token.slice(4) : token
  }
  return null
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

/**
 * Strict raster MIME parser (`strict_parse_no_default`).
 * Strips optional MIME parameters (e.g. `; charset=...`), maps `image/jpg` -> `image/jpeg`,
 * and returns `null` for SVG (`image/svg+xml`) and any non-raster or unknown MIME.
 */
export function parseWorkspaceRasterMime(value: unknown): WorkspaceRasterMime | null {
  if (typeof value !== 'string') return null
  const bare = value.split(';', 1)[0]?.trim().toLowerCase() ?? ''
  switch (bare) {
    case 'image/png':
      return 'image/png'
    case 'image/jpeg':
    case 'image/jpg':
      return 'image/jpeg'
    case 'image/gif':
      return 'image/gif'
    case 'image/webp':
      return 'image/webp'
    default:
      return null
  }
}

export function isWorkspaceRasterMime(value: unknown): value is string {
  return parseWorkspaceRasterMime(value) !== null
}

/**
 * Mirrors OCaml `Wiki_page_name.validate_page_name`:
 * lowercase ASCII letters, digits, and inner hyphens only; never `index` or `log`.
 */
export function isValidWikiSlug(value: unknown): value is string {
  if (typeof value !== 'string' || value.length === 0) return false
  if (!WIKI_SLUG_RE.test(value)) return false
  if (value.startsWith('-') || value.endsWith('-')) return false
  return !RESERVED_WIKI_SLUGS.has(value)
}

/**
 * Mirrors OCaml `Published_artifact.valid_id`:
 * exact length 41, `"artifact-"` followed by 32 lowercase hex chars.
 */
export function isValidPublishedArtifactId(value: unknown): value is string {
  return typeof value === 'string' && value.length === 41 && PUBLISHED_ARTIFACT_ID_RE.test(value)
}

export type WorkspaceEmbed =
  | {
      readonly kind: 'media'
      readonly sha256: string
      readonly path: string
      readonly caption: string | null
      readonly raw: string
    }
  | {
      readonly kind: 'wiki'
      readonly slug: string
      readonly label: string | null
      readonly raw: string
    }
  | {
      readonly kind: 'artifact'
      readonly id: string
      readonly label: string | null
      readonly raw: string
    }
  | {
      readonly kind: 'invalid'
      readonly rawTarget: string
      readonly label: string | null
      readonly raw: string
    }
  | {
      readonly kind: 'unsupported'
      readonly scheme: string
      readonly rawTarget: string
      readonly label: string | null
      readonly raw: string
    }

/**
 * Pure parser for the inner body of `![[...]]`.
 * Accepts canonical `media:att_<64hex>` (routing to `/api/v1/attachments/att_<64hex>`)
 * and legacy `media:<64hex>` (routing to `/api/v1/media/<64hex>`).
 * Never coerces unknown schemes or malformed targets into valid slugs/paths.
 */
export function parseObsidianEmbed(inner: string, raw = `![[${inner}]]`): WorkspaceEmbed {
  const pipeIndex = inner.indexOf('|')
  const rawTargetPart = pipeIndex === -1 ? inner : inner.slice(0, pipeIndex)
  const rawLabelPart = pipeIndex === -1 ? null : inner.slice(pipeIndex + 1).trim()
  const label = rawLabelPart && rawLabelPart.length > 0 ? rawLabelPart : null
  const target = rawTargetPart.trim()

  if (!target) {
    return { kind: 'invalid', rawTarget: target, label, raw }
  }

  const colonIndex = target.indexOf(':')
  if (colonIndex !== -1) {
    const scheme = target.slice(0, colonIndex).trim()
    const rest = target.slice(colonIndex + 1).trim()
    switch (scheme) {
      case 'media': {
        if (isWorkspaceAttachmentId(rest)) {
          return {
            kind: 'media',
            sha256: rest.slice(4),
            path: `${WORKSPACE_ATTACHMENT_PREFIX}${rest}`,
            caption: label,
            raw,
          }
        }
        const legacyPath = workspaceMediaPath(rest)
        return legacyPath
          ? { kind: 'media', sha256: rest, path: legacyPath, caption: label, raw }
          : { kind: 'invalid', rawTarget: target, label, raw }
      }
      case 'wiki':
        return isValidWikiSlug(rest)
          ? { kind: 'wiki', slug: rest, label, raw }
          : { kind: 'invalid', rawTarget: target, label, raw }
      case 'artifact':
        return isValidPublishedArtifactId(rest)
          ? { kind: 'artifact', id: rest, label, raw }
          : { kind: 'invalid', rawTarget: target, label, raw }
      default:
        return {
          kind: 'unsupported',
          scheme: scheme || 'unknown',
          rawTarget: target,
          label,
          raw,
        }
    }
  }

  return isValidWikiSlug(target)
    ? { kind: 'wiki', slug: target, label, raw }
    : { kind: 'invalid', rawTarget: target, label, raw }
}
