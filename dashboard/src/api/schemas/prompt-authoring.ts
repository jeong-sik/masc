import * as v from 'valibot'

// Prompt_registry.authoring_issue_json owns the required wire report.
// Only [] reports a clean catalog; missing or malformed diagnostics are errors.
const authoringIssues = v.array(v.object({
  code: v.literal('invalid_operator_surface'),
  field: v.literal('operator_surface'),
  value: v.string(),
  source_file: v.string(),
}))

export type PromptAuthoringIssue = v.InferOutput<typeof authoringIssues>[number]

export function parsePromptAuthoringIssues(raw: unknown): PromptAuthoringIssue[] {
  return v.parse(authoringIssues, raw)
}
