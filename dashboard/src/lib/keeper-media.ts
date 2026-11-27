/**
 * Canonical Workspace Media Path, Closed Raster MIME & Unified Embed Grammar SSOT.
 *
 * Matches the frozen wire/type contract (`docs/rfc/RFC-workspace-media-and-rich-embed.md`):
 * - Media URI: `/api/v1/media/<64-lowercase-hex-sha256>`
 * - Closed raster MIME union: `image/png | image/jpeg | image/gif | image/webp`
 *   (`image/svg+xml` is explicitly rejected — same-origin stored XSS vector).
 * - Unified Obsidian embed grammar:
 *   - `![[media:<sha256>]]` / `![[media:<sha256>|caption]]`
 *   - `![[wiki:<slug>]]` / `![[<slug>]]` / `![[wiki:<slug>|label]]`
 *   - `![[artifact:<id>]]` / `![[artifact:<id>|label]]`
 *   - Unknown `<scheme>:<raw>` -> `unsupported` (never coerced to wiki slug)
 *   - Malformed known scheme target -> `invalid` (never silently repaired)
 */

export const WORKSPACE_MEDIA_PREFIX = '/api/v1/media/'

// Matches server ceiling of Env_config_keeper.KeeperGeneratedMedia.max_bytes (50 MiB).
export const WORKSPACE_MEDIA_MAX_BYTES = 50 * 1024 * 1024

export const WORKSPACE_RASTER_MIMES = [
  'image/png',
  'image/jpeg',
  'image/gif',
  'image/webp',
] as const

export type WorkspaceRasterMime = (typeof WORKSPACE_RASTER_MIMES)[number]

const STORE_TOKEN_RE = /^[0-9a-f]{64}$/
const WIKI_SLUG_RE = /^[a-z0-9-]+$/
const PUBLISHED_ARTIFACT_ID_RE = /^artifact-[0-9a-f]{32}$/
const RESERVED_WIKI_SLUGS = new Set(['index', 'log'])

export function isWorkspaceMediaSha256(value: unknown): value is string {
  return typeof value === 'string' && value.length === 64 && STORE_TOKEN_RE.test(value)
}

export function isWorkspaceMediaPath(value: unknown): value is string {
  if (typeof value !== 'string' || !value.startsWith(WORKSPACE_MEDIA_PREFIX)) return false
  return isWorkspaceMediaSha256(value.slice(WORKSPACE_MEDIA_PREFIX.length))
}

export function workspaceMediaPath(sha256: string): string | null {
  return isWorkspaceMediaSha256(sha256) ? `${WORKSPACE_MEDIA_PREFIX}${sha256}` : null
}

export function extractWorkspaceMediaSha256(value: unknown): string | null {
  if (!isWorkspaceMediaPath(value)) return null
  return value.slice(WORKSPACE_MEDIA_PREFIX.length)
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
        const path = workspaceMediaPath(rest)
        return path
          ? { kind: 'media', sha256: rest, path, caption: label, raw }
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
