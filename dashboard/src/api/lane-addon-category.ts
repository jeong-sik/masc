import { Schema } from 'effect'

/** Display metadata declared by the package, independent of service authority. */
export const LANE_ADDON_CATEGORIES = [
  'memory_judgment', 'browser', 'external_communications', 'voice_media',
  'execution_environment', 'analysis',
] as const
export const laneAddonCategorySchema = Schema.Literal(...LANE_ADDON_CATEGORIES)
export type LaneAddonCategory = Schema.Schema.Type<typeof laneAddonCategorySchema>
// Only an omitted field is unclassified. Explicit null/undefined is invalid.
export const optionalLaneAddonCategory = Schema.optionalWith(laneAddonCategorySchema, { exact: true })
