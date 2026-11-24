/**
 * Pure TOML Lane CRUD & Unified Diff Engine for `5 Runtime > Lanes`.
 *
 * Parses and surgically edits `[runtime.lanes.<id>]` (`candidates = [...]`) and
 * `[runtime.exact_output_lanes.<id>]` (`slots = [...]`, optional `max_output_tokens`,
 * `enabled`) inside `runtime.toml` (`source_text`) without requiring `$EDITOR`.
 * Preserves comments, ordering, and every unrelated table untouched.
 */

import { createTwoFilesPatch } from 'diff'
import { err, ok, type Result } from '../../lib/result'

export type EditableLaneKind = 'failover' | 'exact_output'

export interface ParsedTomlLane {
  readonly kind: EditableLaneKind
  readonly id: string
  readonly candidates: readonly string[]
  readonly maxOutputTokens?: number
  readonly enabled?: boolean
}

export interface UpsertLaneSpec {
  readonly kind: EditableLaneKind
  readonly id: string
  readonly candidates: readonly string[]
  readonly maxOutputTokens?: number | null
  readonly enabled?: boolean
}

const LANE_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/
const BARE_TOML_KEY_RE = /^[A-Za-z0-9_-]+$/

function unquoteTomlKey(raw: string): string {
  const t = raw.trim()
  if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
    return t.slice(1, -1)
  }
  return t
}

export function renderTomlKeySegment(segment: string): string {
  return BARE_TOML_KEY_RE.test(segment) ? segment : JSON.stringify(segment)
}

function tablePrefixForKind(kind: EditableLaneKind): string {
  return kind === 'failover' ? 'runtime.lanes.' : 'runtime.exact_output_lanes.'
}

function renderTableHeader(kind: EditableLaneKind, id: string): string {
  return `[${tablePrefixForKind(kind)}${renderTomlKeySegment(id)}]`
}

interface TableSpan {
  readonly kind: EditableLaneKind
  readonly id: string
  readonly startLine: number
  readonly endLine: number // exclusive
}

/**
 * Strips a trailing `# ...` TOML comment while respecting single- and double-quoted strings.
 */
function stripTomlComment(line: string): string {
  let quote: 'none' | 'double' | 'single' = 'none'
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]!
    if (quote === 'none') {
      if (ch === '#') return line.slice(0, i)
      if (ch === '"') quote = 'double'
      else if (ch === "'") quote = 'single'
    } else if (quote === 'double') {
      if (ch === '\\') i += 1
      else if (ch === '"') quote = 'none'
    } else if (ch === "'") {
      quote = 'none'
    }
  }
  return line
}

function unquoteBasicString(raw: string): string {
  let out = ''
  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i]!
    if (ch === '\\' && i + 1 < raw.length) {
      const next = raw[i + 1]!
      i += 1
      if (next === '"' || next === '\\') out += next
      else if (next === 'n') out += '\n'
      else if (next === 't') out += '\t'
      else if (next === 'r') out += '\r'
      else out += next
    } else {
      out += ch
    }
  }
  return out
}

function parseTableHeader(line: string): { readonly kind: EditableLaneKind; readonly id: string } | null {
  const stripped = stripTomlComment(line).trim()
  if (!stripped.startsWith('[') || stripped.startsWith('[[') || !stripped.endsWith(']')) {
    return null
  }
  const inner = stripped.slice(1, -1).trim()
  if (inner.startsWith('runtime.lanes.')) {
    const rest = inner.slice('runtime.lanes.'.length).trim()
    if (!rest || (rest.includes('.') && !rest.startsWith('"') && !rest.startsWith("'"))) {
      return null
    }
    return { kind: 'failover', id: unquoteTomlKey(rest) }
  }
  if (inner.startsWith('runtime.exact_output_lanes.')) {
    const rest = inner.slice('runtime.exact_output_lanes.'.length).trim()
    if (!rest || (rest.includes('.') && !rest.startsWith('"') && !rest.startsWith("'"))) {
      return null
    }
    return { kind: 'exact_output', id: unquoteTomlKey(rest) }
  }
  return null
}

function isAnyTableHeader(line: string): boolean {
  const stripped = stripTomlComment(line).trim()
  return stripped.startsWith('[') && stripped.endsWith(']')
}

/**
 * Quote-aware bracket delta for a single line outside strings and `#` comments.
 */
function scanLineBracketDelta(line: string): number {
  let quote: 'none' | 'double' | 'single' = 'none'
  let delta = 0
  for (let i = 0; i < line.length; i++) {
    const ch = line[i]!
    if (quote === 'none') {
      if (ch === '#') break
      if (ch === '"') quote = 'double'
      else if (ch === "'") quote = 'single'
      else if (ch === '[') delta += 1
      else if (ch === ']') delta -= 1
    } else if (quote === 'double') {
      if (ch === '\\') i += 1
      else if (ch === '"') quote = 'none'
    } else if (ch === "'") {
      quote = 'none'
    }
  }
  return delta
}

function findLaneTableSpans(lines: readonly string[]): readonly TableSpan[] {
  const spans: TableSpan[] = []
  let i = 0
  while (i < lines.length) {
    const parsed = parseTableHeader(lines[i]!)
    if (!parsed) {
      i += 1
      continue
    }
    let end = i + 1
    let openArrayDepth = 0
    while (end < lines.length) {
      const curLine = lines[end]!
      if (openArrayDepth === 0 && isAnyTableHeader(curLine)) break
      openArrayDepth = Math.max(0, openArrayDepth + scanLineBracketDelta(curLine))
      end += 1
    }
    spans.push({ kind: parsed.kind, id: parsed.id, startLine: i, endLine: end })
    i = end
  }
  return spans
}

interface ScannedTomlArray {
  readonly startLine: number
  readonly endLine: number
  readonly items: readonly string[]
}

/**
 * Quote-aware scanner for a `key = [...]` string array inside table body lines.
 * Safely handles `#` and `]` inside both double-quoted (`"..."`) and single-quoted
 * (`'...'`) TOML strings as well as comments containing brackets or quotes.
 */
function scanTomlStringArray(bodyLines: readonly string[], keyName: string): ScannedTomlArray | null {
  const keyRe = new RegExp(`^\\s*${keyName}\\s*=`)
  let openArrayDepth = 0

  for (let i = 0; i < bodyLines.length; i++) {
    const line = bodyLines[i]!
    if (openArrayDepth > 0) {
      openArrayDepth = Math.max(0, openArrayDepth + scanLineBracketDelta(line))
      continue
    }
    const match = keyRe.exec(line)
    if (!match) {
      openArrayDepth = Math.max(0, openArrayDepth + scanLineBracketDelta(line))
      continue
    }

    const eqIdx = match[0].length
    let depth = 0
    let started = false
    const items: string[] = []

    for (let j = i; j < bodyLines.length; j++) {
      const cur = bodyLines[j]!
      let col = j === i ? eqIdx : 0
      while (col < cur.length) {
        const ch = cur[col]!
        if (ch === '#') break
        if (!started) {
          if (ch === '[') {
            started = true
            depth = 1
          }
          col += 1
          continue
        }
        if (ch === '[') {
          depth += 1
          col += 1
          continue
        }
        if (ch === ']') {
          depth -= 1
          col += 1
          if (depth === 0) {
            return { startLine: i, endLine: j, items }
          }
          continue
        }
        if (ch === '"') {
          let raw = ''
          col += 1
          while (col < cur.length) {
            const c = cur[col]!
            if (c === '\\' && col + 1 < cur.length) {
              raw += c + cur[col + 1]!
              col += 2
              continue
            }
            if (c === '"') {
              col += 1
              break
            }
            raw += c
            col += 1
          }
          if (depth === 1) {
            const trimmed = unquoteBasicString(raw).trim()
            if (trimmed) items.push(trimmed)
          }
          continue
        }
        if (ch === "'") {
          let raw = ''
          col += 1
          while (col < cur.length && cur[col] !== "'") {
            raw += cur[col]!
            col += 1
          }
          if (col < cur.length && cur[col] === "'") col += 1
          if (depth === 1) {
            const trimmed = raw.trim()
            if (trimmed) items.push(trimmed)
          }
          continue
        }
        col += 1
      }
      if (!started) {
        // Key was not assigned an array; stop scanning for this match
        return { startLine: i, endLine: i, items: [] }
      }
    }
    return { startLine: i, endLine: bodyLines.length - 1, items }
  }
  return null
}

function extractStringArray(bodyLines: readonly string[], keyName: string): readonly string[] {
  return scanTomlStringArray(bodyLines, keyName)?.items ?? []
}

function extractIntKey(blockText: string, keyName: string): number | undefined {
  const re = new RegExp(`^\\s*${keyName}\\s*=\\s*([+]?[0-9_]+)\\b`, 'm')
  const match = re.exec(blockText)
  if (!match) return undefined
  const n = Number.parseInt(match[1]!.replace(/_/g, ''), 10)
  return Number.isSafeInteger(n) ? n : undefined
}

function extractBoolKey(blockText: string, keyName: string): boolean | undefined {
  const re = new RegExp(`^\\s*${keyName}\\s*=\\s*(true|false)\\b`, 'm')
  const match = re.exec(blockText)
  if (!match) return undefined
  return match[1] === 'true'
}

export function parseLanesFromToml(sourceText: string): readonly ParsedTomlLane[] {
  const lines = sourceText.split(/\r?\n/)
  const spans = findLaneTableSpans(lines)
  return spans.map((span) => {
    const bodyLines = lines.slice(span.startLine + 1, span.endLine)
    const body = bodyLines.join('\n')
    const keyName = span.kind === 'failover' ? 'candidates' : 'slots'
    const candidates = extractStringArray(bodyLines, keyName)
    if (span.kind === 'exact_output') {
      return {
        kind: 'exact_output',
        id: span.id,
        candidates,
        maxOutputTokens: extractIntKey(body, 'max_output_tokens'),
        enabled: extractBoolKey(body, 'enabled'),
      }
    }
    return {
      kind: 'failover',
      id: span.id,
      candidates,
    }
  })
}

export function validateLaneId(rawId: string): Result<string, string> {
  const trimmed = rawId.trim()
  if (!trimmed) return err('레인 ID를 입력하세요.')
  if (!LANE_ID_RE.test(trimmed)) {
    return err('레인 ID는 영문/숫자로 시작하며 영문, 숫자, ., _, - 만 사용할 수 있습니다.')
  }
  return ok(trimmed)
}

export function reorderCandidate(
  candidates: readonly string[],
  index: number,
  direction: 'up' | 'down',
): readonly string[] {
  const target = direction === 'up' ? index - 1 : index + 1
  if (index < 0 || index >= candidates.length || target < 0 || target >= candidates.length) {
    return candidates
  }
  const next = [...candidates]
  const tmp = next[index]!
  next[index] = next[target]!
  next[target] = tmp
  return next
}

function renderTomlStringArray(keyName: string, values: readonly string[]): readonly string[] {
  if (values.length <= 2) {
    return [`${keyName} = [${values.map((v) => JSON.stringify(v)).join(', ')}]`]
  }
  return [
    `${keyName} = [`,
    ...values.map((v) => `  ${JSON.stringify(v)},`),
    ']',
  ]
}

function replaceOrInsertArrayKey(
  bodyLines: readonly string[],
  keyName: string,
  values: readonly string[],
): string[] {
  const rendered = renderTomlStringArray(keyName, values)
  const scanned = scanTomlStringArray(bodyLines, keyName)
  if (scanned) {
    return [...bodyLines.slice(0, scanned.startLine), ...rendered, ...bodyLines.slice(scanned.endLine + 1)]
  }
  return [...rendered, ...bodyLines]
}

function replaceOrInsertScalarKey(
  bodyLines: readonly string[],
  keyName: string,
  renderedLine: string | null,
): string[] {
  const keyRe = new RegExp(`^\\s*${keyName}\\s*=`)
  const idx = bodyLines.findIndex((line) => keyRe.test(line))
  if (idx >= 0) {
    if (renderedLine === null) {
      return [...bodyLines.slice(0, idx), ...bodyLines.slice(idx + 1)]
    }
    return [...bodyLines.slice(0, idx), renderedLine, ...bodyLines.slice(idx + 1)]
  }
  if (renderedLine === null) return [...bodyLines]
  // Insert before trailing blank lines
  let insertAt = bodyLines.length
  while (insertAt > 0 && bodyLines[insertAt - 1]!.trim() === '') {
    insertAt -= 1
  }
  return [...bodyLines.slice(0, insertAt), renderedLine, ...bodyLines.slice(insertAt)]
}

export function upsertLaneInToml(
  sourceText: string,
  spec: UpsertLaneSpec,
): Result<string, string> {
  const idRes = validateLaneId(spec.id)
  if (!idRes.ok) return idRes
  const laneId = idRes.value

  const cleanedCandidates: string[] = []
  const seen = new Set<string>()
  for (const raw of spec.candidates) {
    const c = raw.trim()
    if (!c || seen.has(c)) continue
    seen.add(c)
    cleanedCandidates.push(c)
  }
  if (cleanedCandidates.length === 0) {
    return err('최소 1개 이상의 후보 Runtime ID를 추가하세요.')
  }

  const hasTrailingNewline = sourceText.endsWith('\n')
  const lines = sourceText.split(/\r?\n/)
  if (hasTrailingNewline && lines[lines.length - 1] === '') {
    lines.pop()
  }

  const spans = findLaneTableSpans(lines)
  const existing = spans.find((s) => s.kind === spec.kind && s.id === laneId)
  const arrayKey = spec.kind === 'failover' ? 'candidates' : 'slots'

  let nextLines: string[]
  if (existing) {
    let body = lines.slice(existing.startLine + 1, existing.endLine)
    body = replaceOrInsertArrayKey(body, arrayKey, cleanedCandidates)
    if (spec.kind === 'exact_output') {
      if (spec.maxOutputTokens !== undefined) {
        body = replaceOrInsertScalarKey(
          body,
          'max_output_tokens',
          spec.maxOutputTokens !== null && spec.maxOutputTokens > 0
            ? `max_output_tokens = ${Math.trunc(spec.maxOutputTokens)}`
            : null,
        )
      }
      if (spec.enabled !== undefined) {
        body = replaceOrInsertScalarKey(body, 'enabled', `enabled = ${spec.enabled ? 'true' : 'false'}`)
      }
    }
    nextLines = [
      ...lines.slice(0, existing.startLine + 1),
      ...body,
      ...lines.slice(existing.endLine),
    ]
  } else {
    const newBlock: string[] = [
      renderTableHeader(spec.kind, laneId),
      ...renderTomlStringArray(arrayKey, cleanedCandidates),
    ]
    if (spec.kind === 'exact_output') {
      if (spec.maxOutputTokens && spec.maxOutputTokens > 0) {
        newBlock.push(`max_output_tokens = ${Math.trunc(spec.maxOutputTokens)}`)
      }
      if (spec.enabled === false) {
        newBlock.push('enabled = false')
      }
    }
    const prefix = lines.length > 0 && lines[lines.length - 1]!.trim() !== ''
      ? [...lines, '']
      : [...lines]
    nextLines = [...prefix, ...newBlock]
  }

  return ok(`${nextLines.join('\n')}\n`)
}

export function deleteLaneFromToml(
  sourceText: string,
  kind: EditableLaneKind,
  laneIdRaw: string,
): Result<string, string> {
  const laneId = laneIdRaw.trim()
  const hasTrailingNewline = sourceText.endsWith('\n')
  const lines = sourceText.split(/\r?\n/)
  if (hasTrailingNewline && lines[lines.length - 1] === '') {
    lines.pop()
  }

  const spans = findLaneTableSpans(lines)
  const existing = spans.find((s) => s.kind === kind && s.id === laneId)
  if (!existing) {
    return err(`runtime.toml에서 [${tablePrefixForKind(kind)}${laneId}] 섹션을 찾지 못했습니다.`)
  }

  let cutStart = existing.startLine
  // Also trim one preceding blank separator line if deleting leaves consecutive blank lines
  if (
    cutStart > 0
    && lines[cutStart - 1]!.trim() === ''
    && (existing.endLine >= lines.length || lines[existing.endLine]!.trim() === '')
  ) {
    cutStart -= 1
  }

  const nextLines = [...lines.slice(0, cutStart), ...lines.slice(existing.endLine)]
  return ok(nextLines.length > 0 ? `${nextLines.join('\n')}\n` : '')
}

export function buildLaneUnifiedDiff(
  beforeText: string,
  afterText: string,
  fileLabel = 'runtime.toml',
): string {
  return createTwoFilesPatch(
    `a/${fileLabel}`,
    `b/${fileLabel}`,
    beforeText,
    afterText,
    'current',
    'proposed',
    { context: 3 },
  )
}
