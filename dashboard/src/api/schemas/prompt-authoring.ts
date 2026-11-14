import { Schema } from 'effect'

// Prompt_registry.authoring_issue_json owns the required wire report.
// Only [] reports a clean catalog; missing or malformed diagnostics are errors.
const AuthoringIssuesSchema = Schema.Array(Schema.Struct({
  code: Schema.Literal('invalid_operator_surface'),
  field: Schema.Literal('operator_surface'),
  value: Schema.String,
  source_file: Schema.String,
}))

export type PromptAuthoringIssue = Schema.Schema.Type<typeof AuthoringIssuesSchema>[number]

export function parsePromptAuthoringIssues(raw: unknown): readonly PromptAuthoringIssue[] {
  return Schema.decodeUnknownSync(AuthoringIssuesSchema)(raw)
}
