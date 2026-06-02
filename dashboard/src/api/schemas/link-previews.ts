/**
 * Link preview schema — schema-at-boundary for
 * `POST /api/v1/dashboard/link-previews` entries.
 *
 * Contract (see dashboard/docs/API_CONTRACT.md):
 * - The preview shape is declared once here; `LinkPreview` type is
 *   derived via `InferOutput`.
 * - `fetchLinkPreviews` passes each entry through `safeParseLinkPreview`
 *   instead of the hand-rolled `normalizeLinkPreview` that previously
 *   lived in `src/api/link-previews.ts`. Unparseable entries drop
 *   silently (same behavior as the prior normalizer returning `null`)
 *   but now the parse result records the drift for future diagnostics.
 * - `kind` is strict (not fallback): entries with an unknown preview
 *   kind are dropped rather than coerced, because a coercion would make
 *   the operator view pretend a rich-media preview exists when the
 *   backend sent something it couldn't classify.
 *
 * Rolled out as part of #7441 (P2 rollout) following pilot #7439.
 */

import {
  nullable,
  object,
  optional,
  picklist,
  safeParse,
  string,
  type InferOutput,
  type SafeParseResult,
} from 'valibot'

const LinkPreviewKindSchema = picklist(['link', 'image'])

const LinkPreviewSchema = object({
  url: string(),
  kind: LinkPreviewKindSchema,
  canonical_url: optional(nullable(string())),
  title: optional(nullable(string())),
  description: optional(nullable(string())),
  site_name: optional(nullable(string())),
  image_url: optional(nullable(string())),
  favicon_url: optional(nullable(string())),
  content_type: optional(nullable(string())),
  fetched_at: optional(nullable(string())),
  cache_state: optional(nullable(string())),
})

export type LinkPreviewKind = InferOutput<typeof LinkPreviewKindSchema>
export type LinkPreview = InferOutput<typeof LinkPreviewSchema>

export function safeParseLinkPreview(
  data: unknown,
): SafeParseResult<typeof LinkPreviewSchema> {
  return safeParse(LinkPreviewSchema, data)
}
