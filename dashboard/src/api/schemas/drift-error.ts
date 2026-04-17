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

function formatIssues(issues: readonly BaseIssue<unknown>[]): string {
  return issues
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
