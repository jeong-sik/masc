import type { AnchoredThread } from './anchored-thread-rail-store'
import type { KeeperEdit } from './keeper-line-ownership-store'

export const IDE_MOCK_FILE_PATH = 'runtime/cascade/router.ts'
export const IDE_MOCK_RELATED_LINE = 18

export const IDE_LAYER_ORDER = ['time', 'parallel', 'tools', 'approve', 'notes', 'explode'] as const
export type IdeLayerKind = (typeof IDE_LAYER_ORDER)[number]

export interface IdeMockAnnotation {
  readonly thread: AnchoredThread
  readonly layers: ReadonlyArray<IdeLayerKind>
  readonly chip: string
}

export const IDE_MOCK_SOURCE = [
  "import { Provider, ProviderKind } from './provider'",
  "import { Turn, TurnId } from './turn'",
  "import { FsmEvent } from '../fsm/state'",
  "import { log } from '../log'",
  "import type { ToolSpec } from './tools'",
  "import { TokenRegistry } from '../tokens/registry'",
  '',
  'export type CascadeReq = {',
  '  model: string',
  '  messages: Array<{ role: string; content: string }>',
  '  tools?: ToolSpec[]',
  "  tool_choice?: 'auto' | 'none'",
  '  max_tokens?: number',
  '}',
  '',
  'export function normalizeTools(req: CascadeReq): CascadeReq {',
  '  // strip empty tools array',
  '  if (req.tools && req.tools.length === 0) {',
  '    const { tools, tool_choice, ...rest } = req',
  '    return rest as CascadeReq',
  '  }',
  '  return req',
  '}',
].join('\n')

export const IDE_MOCK_OWNERSHIP_EVENTS: ReadonlyArray<KeeperEdit> = [
  {
    file_path: IDE_MOCK_FILE_PATH,
    line_start: 1,
    line_end: 6,
    keeper_id: 'nick0cave',
    timestamp_ms: 1_774_960_000_000,
    kind: 'create',
  },
  {
    file_path: IDE_MOCK_FILE_PATH,
    line_start: 8,
    line_end: 14,
    keeper_id: 'sangsu',
    timestamp_ms: 1_774_960_180_000,
    kind: 'edit',
  },
  {
    file_path: IDE_MOCK_FILE_PATH,
    line_start: 16,
    line_end: 23,
    keeper_id: 'masc-improver',
    timestamp_ms: 1_774_960_420_000,
    kind: 'refactor',
  },
]

export const IDE_MOCK_ANNOTATIONS: ReadonlyArray<IdeMockAnnotation> = [
  {
    thread: {
      id: 'thread-schema-tools',
      kind: 'flag',
      author_keeper_id: 'nick0cave',
      anchor: { file_path: IDE_MOCK_FILE_PATH, line_start: 11, line_end: 12, symbol_hint: 'type:CascadeReq.tools' },
      created_ms: Date.UTC(2026, 4, 2, 1, 41, 18),
      body: "This is exactly the tool schema edge we're seeing in prod - keep tools[] and tool_choice paired.",
      reply_count: 2,
      resolved: false,
    },
    layers: ['tools'],
    chip: 'tool',
  },
  {
    thread: {
      id: 'thread-normalize-tool-choice',
      kind: 'question',
      author_keeper_id: 'operator',
      anchor: { file_path: IDE_MOCK_FILE_PATH, line_start: 18, line_end: 19, symbol_hint: 'fn:normalizeTools' },
      created_ms: Date.UTC(2026, 4, 2, 1, 39, 2),
      body: 'Should normalizeTools also handle tool_choice=none? feels like an edge case.',
      reply_count: 1,
      resolved: false,
    },
    layers: ['tools'],
    chip: 'tool',
  },
  {
    thread: {
      id: 'thread-budget-approve',
      kind: 'approve',
      author_keeper_id: 'operator',
      anchor: { file_path: IDE_MOCK_FILE_PATH, line_start: 20, line_end: 20, symbol_hint: 'return:normalized-rest' },
      created_ms: Date.UTC(2026, 4, 2, 1, 22, 41),
      body: 'Budget guard reads well. Ship it when tests pass.',
      reply_count: 0,
      resolved: false,
    },
    layers: ['approve'],
    chip: 'approve',
  },
  {
    thread: {
      id: 'thread-empty-tools-note',
      kind: 'note',
      author_keeper_id: 'operator',
      anchor: { file_path: IDE_MOCK_FILE_PATH, line_start: 17, line_end: 17, symbol_hint: 'comment:empty-tools' },
      created_ms: Date.UTC(2026, 4, 2, 1, 18, 4),
      body: 'telemetry event name needs to match the lifeline schema - will rename later.',
      reply_count: 0,
      resolved: false,
    },
    layers: ['notes'],
    chip: 'note',
  },
  {
    thread: {
      id: 'thread-rest-helper',
      kind: 'suggest',
      author_keeper_id: 'masc-improver',
      anchor: { file_path: IDE_MOCK_FILE_PATH, line_start: 18, line_end: 19, symbol_hint: 'fn:normalizeTools' },
      created_ms: Date.UTC(2026, 4, 2, 1, 14, 52),
      body: 'Could you collapse the rest-spread into a small helper? Same pattern appears in provider.ts.',
      reply_count: 3,
      resolved: false,
    },
    layers: ['tools'],
    chip: 'tool',
  },
]

export const IDE_MOCK_THREADS: ReadonlyArray<AnchoredThread> =
  IDE_MOCK_ANNOTATIONS.map(annotation => annotation.thread)

export function ideMockAnnotationsForLine(line: number): ReadonlyArray<IdeMockAnnotation> {
  if (!Number.isSafeInteger(line) || line < 1) return []
  return IDE_MOCK_ANNOTATIONS.filter(annotation => anchorContainsLine(annotation.thread, line))
}

export function ideMockAnnotationsForLayer(layer: IdeLayerKind): ReadonlyArray<IdeMockAnnotation> {
  return IDE_MOCK_ANNOTATIONS.filter(annotation => annotation.layers.includes(layer))
}

function anchorContainsLine(thread: AnchoredThread, line: number): boolean {
  const { line_start: start, line_end: end } = thread.anchor
  if (start === null || end === null) return false
  return line >= start && line <= end
}
