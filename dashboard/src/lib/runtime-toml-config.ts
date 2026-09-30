import { getStaticTOMLValue, parseTOML, ParseError, type AST } from 'toml-eslint-parser'

export type RuntimeTomlTransportKind = 'endpoint' | 'command' | 'missing'
export type RuntimeTomlCredentialType = 'env' | 'file' | 'inline' | 'none'

export interface RuntimeTomlProvider {
  id: string
  enabled: boolean
  displayName: string
  protocol: string
  transportKind: RuntimeTomlTransportKind
  endpoint: string
  command: string
  accountHome: string
  credentialType: RuntimeTomlCredentialType
  credentialKey: string
  credentialPath: string
  credentialValue: string
  isNonInteractive: boolean
  agent: string
  effort: string
  timeoutS: number | null
  // Declared by its own [providers.<id>] table. False when keys under
  // [providers] or at the top level declare it; the structured editor writes
  // tables and cannot edit that layout.
  ownTable: boolean
}

export interface RuntimeTomlModel {
  id: string
  apiName: string
  maxContext: number | null
  maxPromptBytes: number | null
  toolsSupport: boolean
  thinkingSupport: boolean
  // Capability fields below mirror [models.<id>.capabilities] (SSOT:
  // lib/runtime/runtime_toml.ml). `null` means the key is absent (unknown),
  // kept distinct from a declared `false` so the UI never claims support that
  // the config did not state.
  jsonSupport: boolean | null
  toolChoice: boolean | null
  structuredOutput: boolean | null
  multimodal: boolean | null
  streaming: boolean
}

export interface RuntimeTomlBinding {
  id: string
  providerId: string
  modelId: string
  enabled: boolean
  isDefault: boolean
  maxConcurrent: number | null
  keepAlive: string
  numCtx: number | null
  // per-M token prices from the binding table (runtime_toml.ml:600-601); `null`
  // when the binding omits them (most bindings do).
  priceInput: number | null
  priceOutput: number | null
  // llama-server prefill-liveness opt-in (runtime.toml `return-progress`,
  // RFC-0382 §7); null when the binding omits it.
  returnProgress: boolean | null
}

export interface RuntimeTomlEnvironment {
  defaultRuntimeId: string
  assignments: Record<string, string>
  // Declared [runtime.lanes.<id>] table names. Since RFC-0457 a keeper
  // assignment may name a lane: the server validates assignments lane first,
  // runtime second (runtime.ml assignment_references, Lane_then_runtime).
  laneIds: string[]
  providers: RuntimeTomlProvider[]
  models: RuntimeTomlModel[]
  bindings: RuntimeTomlBinding[]
  warnings: string[]
  parseError: string | null
}

export interface RuntimeTomlImpactSummary {
  defaultRuntimeBefore: string
  defaultRuntimeAfter: string
  defaultRuntimeChanged: boolean
  runtimeAssignmentsChanged: boolean
  providerCountDelta: number
  modelCountDelta: number
  bindingCountDelta: number
  lineDelta: number
  charDelta: number
}

interface TomlSection {
  readonly name: string
  readonly kind: AST.TOMLTable['kind']
  readonly path: readonly string[]
  readonly entries: readonly AST.TOMLKeyValue[]
  readonly start: number
  readonly end: number
}

interface TomlDocument {
  readonly source: string
  readonly lines: string[]
  readonly sections: TomlSection[]
  // Every key under [providers], whatever shape declares it, as the server's
  // loader reads them (declared_provider_ids).
  readonly declaredProviderIds: ReadonlySet<string>
  // Key/value lines before the first table header.
  readonly rootEntries: readonly AST.TOMLKeyValue[]
}

type TomlScalar = string | number | boolean | null

// Parse the complete document so quoted/escaped keys, dotted-key whitespace
// and apparent table headers inside multiline strings have TOML semantics.
// Source ranges let edits preserve spelling, comments and unrelated text.
function parseDocument(sourceText: string): TomlDocument {
  const ast = parseTOML(sourceText, { tomlVersion: '1.0' })
  const lines = sourceText.split('\n')
  const tables = ast.body[0].body.filter((node): node is AST.TOMLTable => node.type === 'TOMLTable')
  const sections = tables.map((table, index): TomlSection => {
    const nextTable = tables[index + 1]
    return {
      name: sourceText.slice(...table.key.range),
      kind: table.kind,
      path: getStaticTOMLValue(table.key),
      entries: table.kind === 'standard' ? table.body : [],
      start: table.loc.start.line - 1,
      end: nextTable ? nextTable.loc.start.line - 1 : lines.length,
    }
  })
  const rootEntries = ast.body[0].body.filter((node): node is AST.TOMLKeyValue => node.type === 'TOMLKeyValue')
  return {
    source: sourceText,
    lines,
    sections,
    declaredProviderIds: declaredKeysUnder(rootEntries, sections, ['providers']),
    rootEntries,
  }
}

// The keys directly under [path], in every shape the server's loader
// accepts: a header at or below it ([providers.<id>], [runtime.lanes.<id>]),
// keys inside a table above it, dotted keys, and inline tables at any depth.
// Read from key nodes rather than from a built object, which would drop an id
// such as __proto__.
function declaredKeysUnder(
  rootEntries: readonly AST.TOMLKeyValue[],
  sections: readonly TomlSection[],
  path: readonly string[],
): ReadonlySet<string> {
  const keys = new Set<string>()
  const reach = (full: readonly string[], below: () => void) => {
    if (full.length > path.length) {
      if (samePath(full.slice(0, path.length), path)) keys.add(full[path.length]!)
    } else if (samePath(full, path.slice(0, full.length))) {
      below()
    }
  }
  const visit = (base: readonly string[], entries: readonly AST.TOMLKeyValue[]) => {
    for (const entry of entries) {
      const full = [...base, ...getStaticTOMLValue(entry.key)]
      const value = entry.value
      reach(full, () => { if (value.type === 'TOMLInlineTable') visit(full, value.body) })
    }
  }
  visit([], rootEntries)
  for (const section of sections) {
    reach(section.path, () => visit(section.path, section.entries))
  }
  return keys
}

function tablePath(name: string): readonly string[] {
  const table = parseTOML(`[${name}]`, { tomlVersion: '1.0' }).body[0].body[0]
  if (table?.type !== 'TOMLTable' || table.kind !== 'standard') {
    throw new Error('Expected a standard TOML table')
  }
  return getStaticTOMLValue(table.key)
}

function samePath(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length && left.every((part, index) => part === right[index])
}

function sectionOf(document: TomlDocument, name: string): TomlSection | null {
  const path = tablePath(name)
  return document.sections.find(section => section.kind === 'standard' && samePath(section.path, path)) ?? null
}

function entryOf(section: TomlSection, key: string): AST.TOMLKeyValue | undefined {
  return section.entries.find(entry => samePath(getStaticTOMLValue(entry.key), [key]))
}

// Serialization validates new identifiers separately from parsing existing text.
const BARE_TOML_KEY = /^[A-Za-z0-9_-]+$/
function serializeTomlKey(key: string): string {
  return BARE_TOML_KEY.test(key) ? key : JSON.stringify(key)
}

function asString(value: TomlScalar | undefined, fallback = ''): string {
  return typeof value === 'string' ? value : fallback
}

function asNumber(value: TomlScalar | undefined): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function asBoolean(value: TomlScalar | undefined, fallback = false): boolean {
  return typeof value === 'boolean' ? value : fallback
}

// Every declared provider, in the shape the server's loader accepts, so the
// provider list and the bindings read the same set.
function providerIds(document: TomlDocument): string[] {
  return [...document.declaredProviderIds]
}

// The key/value nodes of the table at [path], however the text declares them:
// its own [header], dotted keys under a parent table or at the top level, or
// an inline table. A Map keeps every key name, including __proto__.
function tableEntries(document: TomlDocument, path: readonly string[]): Map<string, AST.TOMLKeyValue> {
  const entriesByKey = new Map<string, AST.TOMLKeyValue>()
  const visit = (base: readonly string[], entries: readonly AST.TOMLKeyValue[]) => {
    for (const entry of entries) {
      const full = [...base, ...getStaticTOMLValue(entry.key)]
      const key = full[full.length - 1]
      if (full.length === path.length + 1 && key !== undefined && samePath(full.slice(0, -1), path)) {
        entriesByKey.set(key, entry)
      } else if (
        entry.value.type === 'TOMLInlineTable'
        && full.length <= path.length
        && samePath(full, path.slice(0, full.length))
      ) {
        visit(full, entry.value.body)
      }
    }
  }
  visit([], document.rootEntries)
  for (const section of document.sections) {
    if (section.kind === 'standard') visit(section.path, section.entries)
  }
  return entriesByKey
}

function tableValues(document: TomlDocument, path: readonly string[]): Record<string, TomlScalar> {
  const values: Record<string, TomlScalar> = Object.create(null)
  for (const [key, entry] of tableEntries(document, path)) {
    const value = getStaticTOMLValue(entry.value)
    if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
      values[key] = value
    }
  }
  return values
}

function modelSetModels(document: TomlDocument, name: string): string[] {
  const entry = tableEntries(document, ['model_sets', name]).get('models')
  if (!entry) return []
  const value = getStaticTOMLValue(entry.value)
  return Array.isArray(value) && value.every((id): id is string => typeof id === 'string')
    ? value : []
}

function modelIds(document: TomlDocument): string[] {
  return [...declaredKeysUnder(document.rootEntries, document.sections, ['models'])]
}

// Identity comes from the same parsed TOML paths as providers and models.
// Only a lane's own standard table is an editable declaration.
function laneSections(document: TomlDocument): TomlSection[] {
  return document.sections.filter(section =>
    section.kind === 'standard' && section.path.length === 3
    && section.path[0] === 'runtime' && section.path[1] === 'lanes')
}

function laneIdsFromDocument(document: TomlDocument): string[] {
  return laneSections(document).map(section => section.path[2]!)
}

function laneCandidatesFromDocument(document: TomlDocument, laneId: string): string[] | null {
  const section = laneSections(document).find(section => section.path[2] === laneId)
  if (!section) return null
  const entry = entryOf(section, 'candidates')
  if (!entry) return null
  const values = getStaticTOMLValue(entry.value)
  return Array.isArray(values) && values.every((value): value is string => typeof value === 'string')
    ? values : null
}

// Invalid TOML never supplies a partial order for a whole-lane write. The
// environment reader reports its parse error separately on the surface.
export function declaredRuntimeLanes(sourceText: string): Map<string, string[] | null> {
  try {
    const document = parseDocument(sourceText)
    return new Map(laneIdsFromDocument(document).map(id => [id, laneCandidatesFromDocument(document, id)]))
  } catch (error) {
    if (!(error instanceof ParseError)) throw error
    return new Map()
  }
}

export function declaredRuntimeLaneCandidates(sourceText: string, laneId: string): string[] | null {
  return declaredRuntimeLanes(sourceText).get(laneId) ?? null
}

export function declaredRuntimeLaneIds(sourceText: string): string[] {
  return [...declaredRuntimeLanes(sourceText).keys()]
}

// A binding is a <provider>.<model> table whose provider is declared and is
// not a name another reader owns, the rule the server's loader uses. Every
// other two-segment table ([fusion.presets], [voice.tts],
// [runtime.assignments]) belongs to another reader.
function bindingEntries(
  document: TomlDocument,
  reservedProviderIds: readonly string[],
): Array<{ providerId: string; modelId: string }> {
  return providerIds(document).flatMap(providerId =>
    reservedProviderIds.includes(providerId)
      ? []
      : [...declaredKeysUnder(document.rootEntries, document.sections, [providerId])]
        .map(modelId => ({ providerId, modelId })))
}

function providerFromDocument(document: TomlDocument, id: string): RuntimeTomlProvider {
  const values = tableValues(document, ['providers', id])
  const credentials = tableValues(document, ['providers', id, 'credentials'])
  const endpoint = asString(values.endpoint)
  const command = asString(values.command)
  const credentialType = asString(credentials.type) as RuntimeTomlCredentialType
  return {
    id,
    enabled: asBoolean(values.enabled, true),
    displayName: asString(values['display-name'], asString(values['provider-name'], id)),
    protocol: asString(values.protocol),
    transportKind: endpoint ? 'endpoint' : command ? 'command' : 'missing',
    endpoint,
    command,
    accountHome: asString(values['account-home']),
    credentialType: credentialType === 'env' || credentialType === 'file' || credentialType === 'inline'
      ? credentialType
      : 'none',
    credentialKey: asString(credentials.key),
    credentialPath: asString(credentials.path),
    credentialValue: asString(credentials.value),
    isNonInteractive: asBoolean(values['is-non-interactive']),
    agent: asString(values.agent),
    effort: asString(values.effort),
    timeoutS: asNumber(values['timeout-s']),
    ownTable: document.sections.some(section =>
      section.kind === 'standard' && samePath(section.path, ['providers', id])),
  }
}

function capBoolean(value: TomlScalar | undefined): boolean | null {
  return typeof value === 'boolean' ? value : null
}

function modelFromDocument(document: TomlDocument, id: string): RuntimeTomlModel {
  const values = tableValues(document, ['models', id])
  // Model capabilities live in the nested [models.<id>.capabilities] section,
  // parsed server-side by lib/runtime/runtime_toml.ml:435-451. The earlier
  // reader looked for a `json-support` key on the top-level model table, which
  // never exists in the SSOT config, so JSON-lane validation never fired.
  const caps = tableValues(document, ['models', id, 'capabilities'])
  // thinking-control-format is intentionally NOT read here: Agent Core
  // request-building never consumes runtime.toml's [models.<id>.capabilities]
  // thinking-control-format key (masc #21521 / agentCore models.toml) — it is the
  // Agent Core catalog's effective_capabilities.thinking_control_format that governs
  // the actual request wire. Re-adding a client-side reader for this key
  // would resurrect the inert-config-editing UX this removal fixed.
  const multimodalCap = caps['supports-multimodal-inputs']
  const imageCap = caps['supports-image-input']
  const multimodal =
    typeof multimodalCap === 'boolean' || typeof imageCap === 'boolean'
      ? multimodalCap === true || imageCap === true
      : null
  return {
    id,
    apiName: asString(values['api-name'], asString(values['model-name'], id)),
    maxContext: asNumber(values['max-context']),
    maxPromptBytes: asNumber(values['max-prompt-bytes']),
    toolsSupport: asBoolean(values['tools-support']),
    thinkingSupport: asBoolean(values['thinking-support']),
    jsonSupport: capBoolean(caps['supports-response-format-json']),
    toolChoice: capBoolean(caps['supports-tool-choice']),
    structuredOutput: capBoolean(caps['supports-structured-output']),
    multimodal,
    streaming: asBoolean(values.streaming, true),
  }
}

function bindingFromDocument(
  document: TomlDocument,
  entry: { providerId: string; modelId: string },
): RuntimeTomlBinding {
  const values = tableValues(document, [entry.providerId, entry.modelId])
  return {
    id: `${entry.providerId}.${entry.modelId}`,
    providerId: entry.providerId,
    modelId: entry.modelId,
    enabled: asBoolean(values.enabled, true),
    isDefault: asBoolean(values['is-default']),
    maxConcurrent: asNumber(values['max-concurrent']),
    keepAlive: asString(values['keep-alive']),
    numCtx: asNumber(values['num-ctx']),
    priceInput: asNumber(values['price-input']),
    priceOutput: asNumber(values['price-output']),
    returnProgress:
      values['return-progress'] === undefined
        ? null
        : asBoolean(values['return-progress']),
  }
}

// [reservedProviderIds] is the server's list (RuntimeTomlConfig.reserved_provider_ids).
export function parseRuntimeTomlEnvironment(
  sourceText: string,
  reservedProviderIds: readonly string[],
): RuntimeTomlEnvironment {
  let document: TomlDocument
  try {
    document = parseDocument(sourceText)
  } catch (error) {
    if (!(error instanceof ParseError)) throw error
    const parseError = `TOML ${error.lineNumber}:${error.column + 1}: ${error.message}`
    return { defaultRuntimeId: '', assignments: {}, laneIds: [], providers: [], models: [], bindings: [], warnings: [parseError], parseError }
  }
  const runtimeValues = tableValues(document, ['runtime'])
  const assignmentValues = tableValues(document, ['runtime', 'assignments'])
  const assignments = Object.fromEntries(
    Object.entries(assignmentValues)
      .filter((entry): entry is [string, string] => typeof entry[1] === 'string'),
  )
  const providers = providerIds(document).map(id => providerFromDocument(document, id))
  const models = modelIds(document).map(id => modelFromDocument(document, id))
  const bindings = bindingEntries(document, reservedProviderIds).map(entry => bindingFromDocument(document, entry))
  // Match the loader's explicit-first expansion. A disabled override still
  // owns its provider/model pair and prevents regeneration from the set.
  const explicitIds = new Set(bindings.map(binding => binding.id))
  for (const provider of providers) {
    if (reservedProviderIds.includes(provider.id)) continue
    const set = asString(tableValues(document, ['providers', provider.id])['model-set'])
    if (!set) continue
    for (const modelId of modelSetModels(document, set)) {
      const id = `${provider.id}.${modelId}`
      if (!explicitIds.has(id)) {
        bindings.push(bindingFromDocument(document, { providerId: provider.id, modelId }))
        explicitIds.add(id)
      }
    }
  }
  const warnings: string[] = []
  if (providers.length === 0) warnings.push('providers.* section not found')
  if (models.length === 0) warnings.push('models.* section not found')
  if (bindings.length === 0) warnings.push('provider.model binding section not found')
  return {
    defaultRuntimeId: asString(runtimeValues.default),
    assignments,
    laneIds: laneIdsFromDocument(document),
    providers,
    models,
    bindings,
    warnings,
    parseError: null,
  }
}

export function enabledRuntimeIds(environment: RuntimeTomlEnvironment): string[] {
  const enabledProviderIds = new Set(
    environment.providers.filter(provider => provider.enabled).map(provider => provider.id),
  )
  return environment.bindings
    .filter(binding => binding.enabled && enabledProviderIds.has(binding.providerId))
    .map(binding => binding.id)
}

function sourceLineCount(sourceText: string): number {
  return sourceText.length === 0 ? 1 : sourceText.split('\n').length
}

function sortedSectionEntries(document: TomlDocument, sectionName: string): Array<[string, TomlScalar]> {
  return Object.entries(tableValues(document, tablePath(sectionName))).sort(([left], [right]) =>
    left.localeCompare(right),
  )
}

function runtimeAssignmentsSignature(document: TomlDocument): string {
  return JSON.stringify(sortedSectionEntries(document, 'runtime.assignments'))
}

export function runtimeTomlImpactSummary(
  beforeSourceText: string,
  afterSourceText: string,
  reservedProviderIds: readonly string[],
): RuntimeTomlImpactSummary | null {
  const beforeEnvironment = parseRuntimeTomlEnvironment(beforeSourceText, reservedProviderIds)
  const afterEnvironment = parseRuntimeTomlEnvironment(afterSourceText, reservedProviderIds)
  if (beforeEnvironment.parseError !== null || afterEnvironment.parseError !== null) return null
  const beforeDocument = parseDocument(beforeSourceText)
  const afterDocument = parseDocument(afterSourceText)

  return {
    defaultRuntimeBefore: beforeEnvironment.defaultRuntimeId,
    defaultRuntimeAfter: afterEnvironment.defaultRuntimeId,
    defaultRuntimeChanged: beforeEnvironment.defaultRuntimeId !== afterEnvironment.defaultRuntimeId,
    runtimeAssignmentsChanged:
      runtimeAssignmentsSignature(beforeDocument) !== runtimeAssignmentsSignature(afterDocument),
    providerCountDelta: afterEnvironment.providers.length - beforeEnvironment.providers.length,
    modelCountDelta: afterEnvironment.models.length - beforeEnvironment.models.length,
    bindingCountDelta: afterEnvironment.bindings.length - beforeEnvironment.bindings.length,
    lineDelta: sourceLineCount(afterSourceText) - sourceLineCount(beforeSourceText),
    charDelta: afterSourceText.length - beforeSourceText.length,
  }
}

function serializeString(value: string): string {
  return JSON.stringify(value)
}

function serializeValue(value: string | number | boolean): string {
  if (typeof value === 'string') return serializeString(value)
  if (typeof value === 'boolean') return value ? 'true' : 'false'
  return String(value)
}

function serializeStringArray(values: readonly string[]): string {
  return `[${values.map(serializeString).join(', ')}]`
}

function joinLines(lines: string[]): string {
  return lines.join('\n')
}

function ensureSection(lines: string[], document: TomlDocument, sectionName: string): { lines: string[]; section: TomlSection } {
  const existing = sectionOf(document, sectionName)
  if (existing) return { lines, section: existing }
  const nextLines = [...lines]
  if (nextLines.length > 0 && nextLines[nextLines.length - 1] !== '') nextLines.push('')
  const start = nextLines.length
  nextLines.push(`[${sectionName}]`)
  return {
    lines: nextLines,
    section: { name: sectionName, kind: 'standard', path: tablePath(sectionName), entries: [], start, end: nextLines.length },
  }
}

// Inline tables are closed to later declarations. Missing keys must be
// inserted inside the deepest inline table that owns their path.
function inlineOwnerOf(document: TomlDocument, path: readonly string[]): { path: readonly string[]; table: AST.TOMLInlineTable } | null {
  let owner: { path: readonly string[]; table: AST.TOMLInlineTable } | null = null
  const visit = (base: readonly string[], entries: readonly AST.TOMLKeyValue[]) => {
    for (const entry of entries) {
      const full = [...base, ...getStaticTOMLValue(entry.key)]
      if (entry.value.type === 'TOMLInlineTable' && full.length <= path.length && samePath(full, path.slice(0, full.length))) {
        owner = { path: full, table: entry.value }
        visit(full, entry.value.body)
      }
    }
  }
  visit([], document.rootEntries)
  for (const section of document.sections) {
    if (section.kind === 'standard') visit(section.path, section.entries)
  }
  return owner
}

function replaceValue(sourceText: string, sectionName: string, key: string, serialized: string): string {
  const document = parseDocument(sourceText)
  const path = tablePath(sectionName)
  const entry = tableEntries(document, path).get(key)
  let next: string
  if (entry) {
    next = sourceText.slice(0, entry.value.range[0]) + serialized + sourceText.slice(entry.value.range[1])
  } else {
    const inline = inlineOwnerOf(document, path)
    if (inline) {
      const offset = inline.table.range[1] - 1
      const relative = [...path.slice(inline.path.length), key].map(serializeTomlKey).join('.')
      const addition = `${inline.table.body.length > 0 ? ', ' : ' '}${relative} = ${serialized} `
      next = sourceText.slice(0, offset) + addition + sourceText.slice(offset)
    } else {
      const declared = declaredKeysUnder(document.rootEntries, document.sections, path.slice(0, -1)).has(path[path.length - 1]!)
      const ancestor = declared ? document.sections
        .filter(section => section.kind === 'standard' && section.path.length <= path.length
          && samePath(section.path, path.slice(0, section.path.length)))
        .sort((left, right) => right.path.length - left.path.length)[0] : undefined
      if (declared) {
        // A table defined by dotted keys cannot be declared again with a
        // header. Extend it under its nearest declared ancestor (or root).
        const relative = [...path.slice(ancestor?.path.length ?? 0), key].map(serializeTomlKey).join('.')
        const lines = [...document.lines]
        lines.splice(ancestor?.end ?? document.sections[0]?.start ?? lines.length, 0, `${relative} = ${serialized}`)
        next = joinLines(lines)
      } else {
        const ensured = ensureSection([...document.lines], document, sectionName)
        ensured.lines.splice(ensured.section.end, 0, `${serializeTomlKey(key)} = ${serialized}`)
        next = joinLines(ensured.lines)
      }
    }
  }
  parseDocument(next)
  return next
}

export function setRuntimeTomlKey(sourceText: string, sectionName: string, key: string, value: string | number | boolean): string {
  return replaceValue(sourceText, sectionName, key, serializeValue(value))
}

export function setRuntimeTomlStringArrayKey(sourceText: string, sectionName: string, key: string, values: readonly string[]): string {
  return replaceValue(sourceText, sectionName, key, serializeStringArray(values))
}

export function getRuntimeTomlKey(sourceText: string, sectionName: string, key: string): string | undefined {
  const entry = tableEntries(parseDocument(sourceText), tablePath(sectionName)).get(key)
  return entry ? sourceText.slice(...entry.value.range) : undefined
}

export function deleteRuntimeTomlKey(sourceText: string, sectionName: string, key: string): string {
  const document = parseDocument(sourceText)
  const path = tablePath(sectionName)
  const entry = tableEntries(document, path).get(key)
  if (!entry) return sourceText
  const inline = inlineOwnerOf(document, path)
  if (inline) {
    const index = inline.table.body.indexOf(entry)
    const before = inline.table.body[index - 1]
    const after = inline.table.body[index + 1]
    const start = after ? entry.range[0] : before?.range[1] ?? entry.range[0]
    const end = after?.range[0] ?? entry.range[1]
    const next = sourceText.slice(0, start) + sourceText.slice(end)
    parseDocument(next)
    return next
  }
  const lines = [...document.lines]
  lines.splice(entry.loc.start.line - 1, entry.loc.end.line - entry.loc.start.line + 1)
  return joinLines(lines)
}

export function deleteRuntimeTomlSection(sourceText: string, sectionName: string): string {
  const document = parseDocument(sourceText)
  const section = sectionOf(document, sectionName)
  if (!section) return sourceText
  const lines = [...document.lines]
  lines.splice(section.start, section.end - section.start)
  return joinLines(lines)
}

// [reservedProviderIds] is the server's list. A provider declared under one
// of those names shares its table with another reader, so only its
// [providers.<id>] tables go.
export function cascadeDeleteProvider(
  sourceText: string,
  providerId: string,
  reservedProviderIds: readonly string[],
): string {
  const document = parseDocument(sourceText)
  const runtimeHere = (runtimeId: string) => splitRuntimeId(runtimeId)?.providerId === providerId
  const arrayEdits: Array<{ path: readonly string[]; key: string; values: string[] }> = []
  const readArray = (path: readonly string[], key: string): string[] => {
    const entry = tableEntries(document, path).get(key)
    if (!entry) return []
    const value = getStaticTOMLValue(entry.value)
    if (!Array.isArray(value) || !value.every((id): id is string => typeof id === 'string')) {
      throw new Error(`Cannot delete provider: ${[...path, key].join('.')} must be an array of runtime ids`)
    }
    return value
  }
  const pruneArray = (path: readonly string[], key: string): { changed: boolean; values: string[] } => {
    const previous = readArray(path, key)
    const values = previous.filter(runtimeId => !runtimeHere(runtimeId))
    const changed = values.length !== previous.length
    if (changed) arrayEdits.push({ path, key, values })
    return { changed, values }
  }
  // Check all dependent routes before returning any edit. Removing an
  // account must leave each required lane with a candidate or a slot.
  for (const id of declaredKeysUnder(document.rootEntries, document.sections, ['runtime', 'lanes'])) {
    const result = pruneArray(['runtime', 'lanes', id], 'candidates')
    if (result.changed && result.values.length === 0) {
      throw new Error(`Cannot delete provider ${providerId}: lane ${id} would have no candidates`)
    }
  }
  for (const id of declaredKeysUnder(document.rootEntries, document.sections, ['runtime', 'exact_output_lanes'])) {
    const path = ['runtime', 'exact_output_lanes', id]
    const slots = pruneArray(path, 'slots')
    const cliSlots = pruneArray(path, 'cli_slots')
    if ((slots.changed || cliSlots.changed) && slots.values.length + cliSlots.values.length === 0) {
      throw new Error(`Cannot delete provider ${providerId}: exact-output lane ${id} would have no slots`)
    }
  }
  pruneArray(['runtime'], 'media_failover')
  const canDeleteBindingNamespace = !reservedProviderIds.includes(providerId)
  const sectionsToDelete = document.sections.filter(section =>
    (section.path[0] === 'providers' && section.path[1] === providerId)
    || (canDeleteBindingNamespace && section.path[0] === providerId),
  ).map(section => section.name)

  let next = sourceText
  for (const sec of sectionsToDelete) {
    next = deleteRuntimeTomlSection(next, sec)
  }
  for (const { path, key, values } of arrayEdits) {
    next = setRuntimeTomlStringArrayKey(next, path.map(serializeTomlKey).join('.'), key, values)
  }

  // Also remove from runtime defaults/assignments if they reference this provider
  const nextDocument = parseDocument(next)
  const runtimeValues = tableValues(nextDocument, ['runtime'])
  // A route names its provider before the first dot. It is cleared by that
  // name, not by the bindings read, since a reserved provider has none read.
  // A lane id can start the same way, so a lane declared in any shape keeps
  // its routes.
  const declaredLanes = declaredKeysUnder(nextDocument.rootEntries, nextDocument.sections, ['runtime', 'lanes'])
  const routesToDeleted = (runtimeId: string) => !declaredLanes.has(runtimeId)
    && splitRuntimeId(runtimeId)?.providerId === providerId
  const remainingBindings = enabledRuntimeIds(parseRuntimeTomlEnvironment(next, reservedProviderIds))
  
  if (typeof runtimeValues.default === 'string' && routesToDeleted(runtimeValues.default)) {
    const fallback = remainingBindings[0]
    next = fallback
      ? setRuntimeTomlKey(next, 'runtime', 'default', fallback)
      : deleteRuntimeTomlKey(next, 'runtime', 'default')
  }
  
  // Clean up assignments
  const assignments = tableValues(nextDocument, ['runtime', 'assignments'])
  for (const [key, value] of Object.entries(assignments)) {
    if (typeof value === 'string' && routesToDeleted(value)) {
      next = deleteRuntimeTomlKey(next, 'runtime.assignments', key)
    }
  }
  
  return next
}

export function setRuntimeTomlDefault(sourceText: string, runtimeId: string): string {
  return setRuntimeTomlKey(sourceText, 'runtime', 'default', runtimeId)
}

export function setRuntimeTomlProviderField(
  sourceText: string,
  providerId: string,
  field: 'enabled' | 'display-name' | 'protocol' | 'endpoint' | 'command' | 'is-non-interactive' | 'account-home' | 'agent' | 'effort' | 'timeout-s' | 'exact-body-timeout-s',
  value: string | number | boolean | null,
): string {
  const section = `providers.${serializeTomlKey(providerId)}`
  if (value === null || value === '') {
    return deleteRuntimeTomlKey(sourceText, section, field)
  }
  if (field === 'endpoint') {
    const withEndpoint = setRuntimeTomlKey(sourceText, section, 'endpoint', value)
    return deleteRuntimeTomlKey(withEndpoint, section, 'command')
  }
  if (field === 'command') {
    const withCommand = setRuntimeTomlKey(sourceText, section, 'command', value)
    return deleteRuntimeTomlKey(withCommand, section, 'endpoint')
  }
  return setRuntimeTomlKey(sourceText, section, field, value)
}

export function setRuntimeTomlProviderCredential(
  sourceText: string,
  providerId: string,
  credentialType: RuntimeTomlCredentialType,
  value: string,
): string {
  const section = `providers.${serializeTomlKey(providerId)}.credentials`
  if (credentialType === 'none') return deleteRuntimeTomlSection(sourceText, section)
  const normalizedValue = value.trim()
  if (!normalizedValue) return deleteRuntimeTomlSection(sourceText, section)
  let next = setRuntimeTomlKey(sourceText, section, 'type', credentialType)
  if (credentialType === 'env') {
    next = setRuntimeTomlKey(next, section, 'key', normalizedValue)
    next = deleteRuntimeTomlKey(next, section, 'path')
    return deleteRuntimeTomlKey(next, section, 'value')
  }
  if (credentialType === 'file') {
    next = setRuntimeTomlKey(next, section, 'path', normalizedValue)
    next = deleteRuntimeTomlKey(next, section, 'key')
    return deleteRuntimeTomlKey(next, section, 'value')
  }
  next = setRuntimeTomlKey(next, section, 'value', normalizedValue)
  next = deleteRuntimeTomlKey(next, section, 'key')
  return deleteRuntimeTomlKey(next, section, 'path')
}

export function setRuntimeTomlModelField(
  sourceText: string,
  modelId: string,
  field: 'api-name' | 'max-context' | 'max-prompt-bytes' | 'tools-support' | 'thinking-support' | 'json-support' | 'streaming',
  value: string | number | boolean | null,
): string {
  // The JSON capability is stored in the nested [models.<id>.capabilities]
  // section under the SSOT key the server reads (runtime_toml.ml). Route the
  // legacy `json-support` field there so dashboard-authored models write the
  // key runtime config actually consumes instead of an ignored top-level key.
  if (field === 'json-support') {
    const capabilities = `models.${serializeTomlKey(modelId)}.capabilities`
    if (value === null) {
      return deleteRuntimeTomlKey(sourceText, capabilities, 'supports-response-format-json')
    }
    return setRuntimeTomlKey(sourceText, capabilities, 'supports-response-format-json', value)
  }
  if (value === null) return deleteRuntimeTomlKey(sourceText, `models.${serializeTomlKey(modelId)}`, field)
  return setRuntimeTomlKey(sourceText, `models.${serializeTomlKey(modelId)}`, field, value)
}

// Runtime identifiers separate a bare provider id from the model id at the
// first dot; a model id may itself contain dots and must remain one key.
function splitRuntimeId(runtimeId: string): { providerId: string; modelId: string } | null {
  const boundary = runtimeId.indexOf('.')
  if (boundary <= 0 || boundary === runtimeId.length - 1) return null
  return { providerId: runtimeId.slice(0, boundary), modelId: runtimeId.slice(boundary + 1) }
}

export function setRuntimeTomlBindingField(
  sourceText: string,
  runtimeId: string,
  field: 'enabled' | 'is-default' | 'max-concurrent' | 'keep-alive' | 'num-ctx',
  value: string | number | boolean | null,
): string {
  const parts = splitRuntimeId(runtimeId)
  if (parts === null) throw new Error('Invalid runtime identifier')
  const table = `${serializeTomlKey(parts.providerId)}.${serializeTomlKey(parts.modelId)}`
  if (value === null) return deleteRuntimeTomlKey(sourceText, table, field)
  return setRuntimeTomlKey(sourceText, table, field, value)
}

// Newly created provider/model ids use the same bare-key alphabet as the
// server. Existing table identity comes from the TOML parser above.
const RUNTIME_TOML_ID_PATTERN = /^[A-Za-z0-9_-]+$/

export function isValidRuntimeTomlIdFormat(id: string): boolean {
  return RUNTIME_TOML_ID_PATTERN.test(id)
}

// Ensures the provider x model pin section exists (e.g. `[ollama_cloud.new-model]`)
// without setting any field — an empty binding section is a valid, common shape
// in runtime.toml already (most bindings only carry `is-default`/knobs when they
// deviate from defaults). No-op if the binding already exists.
export function createRuntimeTomlBinding(
  sourceText: string,
  providerId: string,
  modelId: string,
): string {
  const document = parseDocument(sourceText)
  const ensured = ensureSection([...document.lines], document, `${serializeTomlKey(providerId)}.${serializeTomlKey(modelId)}`)
  const next = joinLines(ensured.lines)
  parseDocument(next)
  return next
}
