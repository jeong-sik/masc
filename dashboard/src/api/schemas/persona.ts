import {
  array,
  boolean,
  integer,
  minValue,
  nonEmpty,
  nullable,
  number,
  object,
  pipe,
  string,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

import { parseOrThrow, SchemaDriftError } from './drift-error'

const NonEmptyStringSchema = pipe(string(), nonEmpty())

export const PersonaSummarySchema = object({
  persona_name: NonEmptyStringSchema,
  display_name: NonEmptyStringSchema,
  role: nullable(string()),
  trait: nullable(string()),
  profile_path: NonEmptyStringSchema,
  has_keeper_defaults: boolean(),
})

export const PersonaListResponseSchema = object({
  count: pipe(number(), integer(), minValue(0)),
  personas: array(PersonaSummarySchema),
})

export type PersonaSummary = Readonly<InferOutput<typeof PersonaSummarySchema>>
export type PersonaListResponse = Readonly<{
  count: number
  personas: readonly PersonaSummary[]
}>

export class PersonaSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('persona list', issues)
  }
}

export class PersonaCountMismatchError extends Error {
  readonly declaredCount: number
  readonly decodedCount: number

  constructor(declaredCount: number, decodedCount: number) {
    super(`persona list count mismatch: declared ${declaredCount}, decoded ${decodedCount}`)
    this.name = 'PersonaCountMismatchError'
    this.declaredCount = declaredCount
    this.decodedCount = decodedCount
  }
}

export function parsePersonaListResponse(data: unknown): PersonaListResponse {
  const parsed = parseOrThrow(PersonaSchemaDriftError, PersonaListResponseSchema, data)
  if (parsed.count !== parsed.personas.length) {
    throw new PersonaCountMismatchError(parsed.count, parsed.personas.length)
  }
  return parsed
}
