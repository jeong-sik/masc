import { isRecord, asString, asStringArray } from '../components/common/normalize'
import type {
  CommandPlaneHelpConcept,
  CommandPlaneHelpDocLink,
  CommandPlaneHelpExample,
  CommandPlaneHelpPath,
  CommandPlaneHelpPitfall,
  CommandPlaneHelpResponse,
  CommandPlaneHelpStep,
  CommandPlaneHelpToolGroup,
} from '../types'

function normalizeHelpDoc(raw: unknown): CommandPlaneHelpDocLink | null {
  if (!isRecord(raw)) return null
  const title = asString(raw.title)
  const path = asString(raw.path)
  if (!title || !path) return null
  return { title, path }
}

function normalizeHelpConcept(raw: unknown): CommandPlaneHelpConcept | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const summary = asString(raw.summary)
  if (!id || !title || !summary) return null
  return { id, title, summary }
}

function normalizeHelpStep(raw: unknown): CommandPlaneHelpStep | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const tool = asString(raw.tool)
  const summary = asString(raw.summary)
  if (!id || !title || !tool || !summary) return null
  return {
    id,
    title,
    tool,
    summary,
    success_signals: asStringArray(raw.success_signals),
    pitfalls: asStringArray(raw.pitfalls),
  }
}

function normalizeHelpPath(raw: unknown): CommandPlaneHelpPath | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const summary = asString(raw.summary)
  const whenToUse = asString(raw.when_to_use)
  if (!id || !title || !summary || !whenToUse) return null
  return {
    id,
    title,
    summary,
    when_to_use: whenToUse,
    steps: Array.isArray(raw.steps)
      ? raw.steps
          .map(normalizeHelpStep)
          .filter((item): item is CommandPlaneHelpStep => item !== null)
      : [],
  }
}

function normalizeHelpToolGroup(raw: unknown): CommandPlaneHelpToolGroup | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const description = asString(raw.description)
  if (!id || !title || !description) return null
  return {
    id,
    title,
    description,
    tools: asStringArray(raw.tools),
  }
}

function normalizeHelpPitfall(raw: unknown): CommandPlaneHelpPitfall | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const symptom = asString(raw.symptom)
  const why = asString(raw.why)
  const fixTool = asString(raw.fix_tool)
  const fixSummary = asString(raw.fix_summary)
  if (!id || !title || !symptom || !why || !fixTool || !fixSummary) return null
  return {
    id,
    title,
    symptom,
    why,
    fix_tool: fixTool,
    fix_summary: fixSummary,
  }
}

function normalizeHelpExample(raw: unknown): CommandPlaneHelpExample | null {
  if (!isRecord(raw)) return null
  const id = asString(raw.id)
  const title = asString(raw.title)
  const pathId = asString(raw.path_id)
  const transport = asString(raw.transport)
  if (!id || !title || !pathId || !transport) return null
  return {
    id,
    title,
    path_id: pathId,
    transport,
    request: raw.request,
    response: raw.response,
    notes: asStringArray(raw.notes),
  }
}

export function normalizeHelp(raw: unknown): CommandPlaneHelpResponse {
  const root = isRecord(raw) ? raw : {}
  return {
    version: asString(root.version),
    generated_at: asString(root.generated_at),
    docs: Array.isArray(root.docs)
      ? root.docs
          .map(normalizeHelpDoc)
          .filter((item): item is CommandPlaneHelpDocLink => item !== null)
      : [],
    concepts: Array.isArray(root.concepts)
      ? root.concepts
          .map(normalizeHelpConcept)
          .filter((item): item is CommandPlaneHelpConcept => item !== null)
      : [],
    golden_paths: Array.isArray(root.golden_paths)
      ? root.golden_paths
          .map(normalizeHelpPath)
          .filter((item): item is CommandPlaneHelpPath => item !== null)
      : [],
    tool_groups: Array.isArray(root.tool_groups)
      ? root.tool_groups
          .map(normalizeHelpToolGroup)
          .filter((item): item is CommandPlaneHelpToolGroup => item !== null)
      : [],
    pitfalls: Array.isArray(root.pitfalls)
      ? root.pitfalls
          .map(normalizeHelpPitfall)
          .filter((item): item is CommandPlaneHelpPitfall => item !== null)
      : [],
    examples: Array.isArray(root.examples)
      ? root.examples
          .map(normalizeHelpExample)
          .filter((item): item is CommandPlaneHelpExample => item !== null)
      : [],
  }
}
