import * as v from 'valibot'

// Prompt_registry.authoring_issue_json owns the wire vocabulary. An absent
// field means this server did not report authoring diagnostics; [] is a
// reported clean result. Malformed or unknown diagnostics must not become [].
const authoringIssues = v.array(v.object({
  code: v.literal('invalid_operator_surface'),
  field: v.literal('operator_surface'),
  value: v.string(),
  source_file: v.string(),
}))

export type PromptAuthoringIssue = v.InferOutput<typeof authoringIssues>[number]

export function parsePromptAuthoringIssues(raw: unknown): PromptAuthoringIssue[] | undefined {
  return raw === undefined ? undefined : v.parse(authoringIssues, raw)
}
