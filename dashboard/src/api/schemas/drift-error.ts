// Shared base for schema-at-boundary parse errors.
//
// Subclasses are kept thin (2-line) so callers can keep writing
// `instanceof CompositeSchemaDriftError` — there is a real test caller
// in components/fsm-hub.integration.test.ts that relies on the
// per-endpoint class identity.
//
// `parseOrThrow` wraps `v.safeParse` with `abortEarly: true` so a
// fully-drifted payload does not retain hundreds of issue objects on
// the thrown error (memory-bounded, matches the /simplify review
// recommendation on #7720).

import {
  safeParse,
  type BaseIssue,
  type BaseSchema,
  type Config,
  type InferOutput,
} from 'valibot'

export interface FormatIssuesOptions {
  /**
   * Truncate to the first N issues before formatting. Used by noisy
   * endpoints (e.g. activity graph/swimlane) that should not surface
   * the full issue list in an Error message — three is enough to spot
   * the first failure cluster while keeping the log line bounded.
   */
  readonly maxIssues?: number
}

/**
 * Format a valibot issue list as a `; `-joined string of
 * `<dotted.path>: <message>` segments, using `<root>` for issues
 * whose `path` resolves to an empty array. Exposed so per-domain
 * `SchemaDriftError` subclasses that build their own summary in a
 * `super(...)` call don't have to inline the same `.map(...).join(';')`
 * block — keeps the `<root>` sentinel and the segment shape in one place.
 *
 * `maxIssues` truncates the input before mapping; without it the
 * whole list is formatted (existing default).
 */
export function formatIssues(
  issues: readonly BaseIssue<unknown>[],
  options?: FormatIssuesOptions,
): string {
  const limited = options?.maxIssues !== undefined
    ? issues.slice(0, options.maxIssues)
    : issues
  return limited
    .map(issue => {
      const path = issue.path?.map(p => String(p.key)).join('.') ?? '<root>'
      return `${path}: ${issue.message}`
    })
    .join('; ')
}

export abstract class SchemaDriftError extends Error {
  readonly issues: readonly BaseIssue<unknown>[]
  readonly domain: string

  constructor(domain: string, issues: readonly BaseIssue<unknown>[]) {
    super(`${domain} schema drift: ${formatIssues(issues)}`)
    this.name = new.target.name
    this.domain = domain
    this.issues = issues
  }
}

export function parseOrThrow<
  TSchema extends BaseSchema<unknown, unknown, BaseIssue<unknown>>,
>(
  ErrorCtor: new (issues: readonly BaseIssue<unknown>[]) => SchemaDriftError,
  schema: TSchema,
  data: unknown,
  config: Config<BaseIssue<unknown>> = { abortEarly: true },
): InferOutput<TSchema> {
  const result = safeParse(schema, data, config)
  if (!result.success) {
    throw new ErrorCtor(result.issues)
  }
  return result.output as InferOutput<TSchema>
}
