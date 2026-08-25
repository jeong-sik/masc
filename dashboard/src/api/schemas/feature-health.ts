import { Data, Effect, ParseResult, Schema } from 'effect'

const CountSchema = Schema.NonNegativeInt

const FeatureHealthItemCommon = {
  env_name: Schema.NonEmptyString,
  description: Schema.NonEmptyString,
  category: Schema.NonEmptyString,
  source: Schema.Literal('env', 'boot_override', 'default'),
} as const

const FeatureHealthItemSchema = Schema.Union(
  Schema.Struct({
    ...FeatureHealthItemCommon,
    lifecycle: Schema.Literal('active'),
    is_enabled: Schema.Literal(true),
    status: Schema.Literal('healthy'),
  }),
  Schema.Struct({
    ...FeatureHealthItemCommon,
    lifecycle: Schema.Literal('active'),
    is_enabled: Schema.Literal(false),
    status: Schema.Literal('inactive'),
  }),
  Schema.Struct({
    ...FeatureHealthItemCommon,
    lifecycle: Schema.Literal('experimental'),
    is_enabled: Schema.Boolean,
    status: Schema.Literal('warning'),
  }),
)

const FeatureHealthOverviewSchema = Schema.Struct({
  total_features: CountSchema,
  healthy_count: CountSchema,
  warning_count: CountSchema,
  inactive_count: CountSchema,
  enabled_count: CountSchema,
  overridden_count: CountSchema,
})

const FeatureHealthCategorySchema = Schema.Struct({
  total: CountSchema,
  enabled: CountSchema,
  features: Schema.Array(FeatureHealthItemSchema),
})

const FeatureHealthWireSchema = Schema.Struct({
  generated_at: Schema.JsonNumber.pipe(Schema.nonNegative()),
  overview: FeatureHealthOverviewSchema,
  features_by_category: Schema.Record({
    key: Schema.NonEmptyString,
    value: FeatureHealthCategorySchema,
  }),
  all_features: Schema.Array(FeatureHealthItemSchema),
})

type FeatureHealthWire = Schema.Schema.Type<typeof FeatureHealthWireSchema>

function sameFeature(
  left: FeatureHealthWire['all_features'][number],
  right: FeatureHealthWire['all_features'][number],
): boolean {
  return left.env_name === right.env_name
    && left.description === right.description
    && left.category === right.category
    && left.lifecycle === right.lifecycle
    && left.is_enabled === right.is_enabled
    && left.source === right.source
    && left.status === right.status
}

function featureHealthInvariantIssues(data: FeatureHealthWire) {
  const issues: Array<{ readonly path: ReadonlyArray<PropertyKey>; readonly message: string }> = []
  const addIssue = (
    condition: boolean,
    path: ReadonlyArray<PropertyKey>,
    message: string,
  ): void => {
    if (!condition) issues.push({ path, message })
  }

  const healthyCount = data.all_features.filter(
    feature => feature.status === 'healthy',
  ).length
  const warningCount = data.all_features.filter(
    feature => feature.status === 'warning',
  ).length
  const inactiveCount = data.all_features.filter(
    feature => feature.status === 'inactive',
  ).length
  const enabledCount = data.all_features.filter(
    feature => feature.is_enabled,
  ).length
  const overriddenCount = data.all_features.filter(
    feature => feature.source === 'env',
  ).length

  addIssue(
    data.overview.total_features === data.all_features.length,
    ['overview', 'total_features'],
    'must equal all_features.length',
  )
  addIssue(
    data.overview.healthy_count === healthyCount,
    ['overview', 'healthy_count'],
    'must equal the number of healthy features',
  )
  addIssue(
    data.overview.warning_count === warningCount,
    ['overview', 'warning_count'],
    'must equal the number of warning features',
  )
  addIssue(
    data.overview.inactive_count === inactiveCount,
    ['overview', 'inactive_count'],
    'must equal the number of inactive features',
  )
  addIssue(
    data.overview.enabled_count === enabledCount,
    ['overview', 'enabled_count'],
    'must equal the number of enabled features',
  )
  addIssue(
    data.overview.overridden_count === overriddenCount,
    ['overview', 'overridden_count'],
    'must equal the number of env-sourced features',
  )

  const allFeaturesByName = new Map(
    data.all_features.map(feature => [feature.env_name, feature] as const),
  )
  const allNames = new Set(allFeaturesByName.keys())
  const allCategories = new Set(
    data.all_features.map(feature => feature.category),
  )
  addIssue(
    allNames.size === data.all_features.length,
    ['all_features'],
    'must not contain duplicate env_name values',
  )

  const categorizedFeatures: FeatureHealthWire['all_features'][number][] = []
  for (const [category, categoryData] of Object.entries(
    data.features_by_category,
  )) {
    const enabled = categoryData.features.filter(
      feature => feature.is_enabled,
    ).length
    addIssue(
      categoryData.total === categoryData.features.length,
      ['features_by_category', category, 'total'],
      'must equal features.length',
    )
    addIssue(
      categoryData.enabled === enabled,
      ['features_by_category', category, 'enabled'],
      'must equal the number of enabled features',
    )
    addIssue(
      categoryData.features.every(feature => feature.category === category),
      ['features_by_category', category, 'features'],
      'must contain only features from this category',
    )
    categorizedFeatures.push(...categoryData.features)
  }

  const categoryNames = Object.keys(data.features_by_category)
  addIssue(
    categoryNames.length === allCategories.size
      && categoryNames.every(category => allCategories.has(category)),
    ['features_by_category'],
    'keys must equal the categories present in all_features',
  )

  const categorizedNames = categorizedFeatures.map(feature => feature.env_name)
  const categorizedNameSet = new Set(categorizedNames)
  addIssue(
    categorizedNames.length === data.all_features.length
      && categorizedNameSet.size === allNames.size
      && [...allNames].every(name => categorizedNameSet.has(name)),
    ['features_by_category'],
    'must partition all_features exactly once',
  )
  addIssue(
    categorizedFeatures.every(feature => {
      const canonical = allFeaturesByName.get(feature.env_name)
      return canonical !== undefined && sameFeature(feature, canonical)
    }),
    ['features_by_category'],
    'must contain the same feature values as all_features',
  )

  return issues
}

export const FeatureHealthDataSchema = FeatureHealthWireSchema.pipe(
  Schema.filter(featureHealthInvariantIssues),
)

export type FeatureHealthItem = Schema.Schema.Type<
  typeof FeatureHealthItemSchema
>
export type FeatureStatus = FeatureHealthItem['status']
export type FeatureHealthOverview = Schema.Schema.Type<
  typeof FeatureHealthOverviewSchema
>
export type FeatureHealthCategory = Schema.Schema.Type<
  typeof FeatureHealthCategorySchema
>
export type FeatureHealthData = Schema.Schema.Type<
  typeof FeatureHealthDataSchema
>

export class FeatureHealthSchemaDriftError extends Data.TaggedError(
  'FeatureHealthSchemaDriftError',
)<{
  readonly domain: 'feature-health'
  readonly issues: ReadonlyArray<ParseResult.ArrayFormatterIssue>
  readonly message: string
}> {}

function schemaDriftError(
  error: ParseResult.ParseError,
): FeatureHealthSchemaDriftError {
  const issues = ParseResult.ArrayFormatter.formatErrorSync(error)
  const details = issues
    .map(issue => {
      const path = issue.path.length > 0 ? issue.path.join('.') : '<root>'
      return `${path}: ${issue.message}`
    })
    .join('; ')
  return new FeatureHealthSchemaDriftError({
    domain: 'feature-health',
    issues,
    message: `feature-health schema drift: ${details}`,
  })
}

const STRICT_PARSE_OPTIONS = {
  errors: 'all',
  onExcessProperty: 'error',
} as const

export function decodeFeatureHealthData(
  data: unknown,
): Effect.Effect<FeatureHealthData, FeatureHealthSchemaDriftError> {
  return Schema.decodeUnknown(
    FeatureHealthDataSchema,
    STRICT_PARSE_OPTIONS,
  )(data).pipe(Effect.mapError(schemaDriftError))
}
