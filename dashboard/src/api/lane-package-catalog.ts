import { Schema } from 'effect'
import { get } from './core'

const text = Schema.NonEmptyString
const entry = Schema.Union(
  Schema.Struct({ kind: Schema.Literal('folder'), path: text }),
  Schema.Struct({ kind: Schema.Literal('issue'), path: text, message: text }),
  Schema.Struct({ kind: Schema.Literal('package'), manifest_path: text, title: text,
    revision: text, description: Schema.NullOr(Schema.String) }),
)
const catalog = Schema.Struct({ directory: text, parent: Schema.NullOr(text), entries: Schema.Array(entry) })
const preview = Schema.Struct({ manifest_path: text,
  package: Schema.Struct({ title: text, revision: text, image: text, binding_schema: Schema.Unknown }),
  image: Schema.Union(Schema.Struct({ state: Schema.Literal('available'), digest: text }),
    Schema.Struct({ state: Schema.Literal('unverified'), detail: text })),
})
export type LanePackageCatalog = Schema.Schema.Type<typeof catalog>
export type LanePackagePreview = Schema.Schema.Type<typeof preview>
export const parseLanePackageCatalog = Schema.decodeUnknownSync(catalog)
export const parseLanePackagePreview = Schema.decodeUnknownSync(preview)
export async function fetchLanePackageCatalog(directory: string | null, signal?: AbortSignal): Promise<LanePackageCatalog> {
  const query = directory === null ? '' : `?${new URLSearchParams({ directory })}`
  return parseLanePackageCatalog(await get<unknown>(`/api/v1/lane-addons/package-catalog${query}`, { signal }))
}
export async function fetchLanePackagePreview(manifestPath: string, signal?: AbortSignal): Promise<LanePackagePreview> {
  return parseLanePackagePreview(await get<unknown>(`/api/v1/lane-addons/package-preview?${new URLSearchParams({ manifest_path: manifestPath })}`, { signal }))
}
