export type RuntimeTomlTransportKind = 'endpoint' | 'command' | 'missing'
export type RuntimeTomlCredentialType = 'env' | 'file' | 'inline' | 'none'

export interface RuntimeTomlProvider {
  id: string
  displayName: string
  protocol: string
  transportKind: RuntimeTomlTransportKind
  endpoint: string
  command: string
  credentialType: RuntimeTomlCredentialType
  credentialKey: string
  credentialPath: string
  credentialValue: string
}

export interface RuntimeTomlModel {
  id: string
  apiName: string
  maxContext: number | null
  toolsSupport: boolean
  thinkingSupport: boolean
  jsonSupport: boolean | null
  streaming: boolean
}

export interface RuntimeTomlBinding {
  id: string
  providerId: string
  modelId: string
  isDefault: boolean
  maxConcurrent: number | null
  keepAlive: string
  numCtx: number | null
}

export interface RuntimeTomlEnvironment {
  defaultRuntimeId: string
  librarianRuntimeId: string
  crossVerifierRuntimeId: string
  assignments: Record<string, string>
  providers: RuntimeTomlProvider[]
  models: RuntimeTomlModel[]
  bindings: RuntimeTomlBinding[]
  warnings: string[]
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
  readonly start: number
  readonly end: number
}

interface TomlDocument {
  readonly lines: string[]
  readonly sections: TomlSection[]
}

type TomlScalar = string | number | boolean | null

// Mirrors the backend's reserved_namespaces (lib/runtime/runtime_toml.ml:554).
// A provider/model id equal to one of these would collide with a top-level
// TOML namespace once used as a binding's first segment (`[<id>.<model>]`).
const RESERVED_TOP_LEVEL = new Set([
  'providers',
  'models',
  'runtime',
  'system',
  'routes',
  'profiles',
  'web_search',
])

function parseDocument(sourceText: string): TomlDocument {
  const lines = sourceText.split('\n')
  const headers: Array<{ name: string; index: number }> = []
  for (let index = 0; index < lines.length; index += 1) {
    const match = lines[index]?.match(/^\s*\[([^\]]+)\]\s*(?:#.*)?$/)
    if (match?.[1]) headers.push({ name: match[1].trim(), index })
  }
  const sections = headers.map((header, index): TomlSection => ({
    name: header.name,
    start: header.index,
    end: headers[index + 1]?.index ?? lines.length,
  }))
  return { lines, sections }
}

function sectionOf(document: TomlDocument, name: string): TomlSection | null {
  return document.sections.find(section => section.name === name) ?? null
}

function keyLineMatch(line: string): RegExpMatchArray | null {
  return line.match(/^(\s*)([A-Za-z0-9_-]+)(\s*=\s*)(.*)$/)
}

function stripInlineComment(raw: string): string {
  let quote: '"' | "'" | null = null
  let escaped = false
  for (let index = 0; index < raw.length; index += 1) {
    const char = raw[index]
    if (escaped) {
      escaped = false
      continue
    }
    if (char === '\\' && quote === '"') {
      escaped = true
      continue
    }
    if (char === '"' && quote !== "'") {
      quote = quote === '"' ? null : '"'
      continue
    }
    if (char === "'" && quote !== '"') {
      quote = quote === "'" ? null : "'"
      continue
    }
    if (char === '#' && quote === null) return raw.slice(0, index).trim()
  }
  return raw.trim()
}

function parseStringLiteral(raw: string): string | null {
  const trimmed = raw.trim()
  if (!trimmed.startsWith('"') || !trimmed.endsWith('"')) return null
  try {
    return JSON.parse(trimmed) as string
  } catch {
    return trimmed.slice(1, -1)
  }
}

function parseTomlScalar(raw: string): TomlScalar {
  const value = stripInlineComment(raw)
  const stringValue = parseStringLiteral(value)
  if (stringValue !== null) return stringValue
  if (value === 'true') return true
  if (value === 'false') return false
  if (/^-?\d+$/.test(value)) return Number.parseInt(value, 10)
  if (/^-?\d+\.\d+$/.test(value)) return Number.parseFloat(value)
  return value === '' ? null : value
}

function sectionValues(document: TomlDocument, name: string): Record<string, TomlScalar> {
  const section = sectionOf(document, name)
  if (!section) return {}
  const values: Record<string, TomlScalar> = {}
  for (let index = section.start + 1; index < section.end; index += 1) {
    const line = document.lines[index] ?? ''
    const match = keyLineMatch(line)
    if (!match?.[2] || match[0].trimStart().startsWith('#')) continue
    values[match[2]] = parseTomlScalar(match[4] ?? '')
  }
  return values
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

function providerIds(document: TomlDocument): string[] {
  return document.sections
    .map(section => section.name.match(/^providers\.([^.]+)$/)?.[1])
    .filter((id): id is string => Boolean(id))
}

function modelIds(document: TomlDocument): string[] {
  return document.sections
    .map(section => section.name.match(/^models\.([^.]+)$/)?.[1])
    .filter((id): id is string => Boolean(id))
}

function bindingSections(document: TomlDocument): Array<{ providerId: string; modelId: string; section: string }> {
  return document.sections
    .map(section => {
      const parts = section.name.split('.')
      if (parts.length !== 2 || RESERVED_TOP_LEVEL.has(parts[0] ?? '')) return null
      return { providerId: parts[0] ?? '', modelId: parts[1] ?? '', section: section.name }
    })
    .filter((entry): entry is { providerId: string; modelId: string; section: string } => {
      return Boolean(entry?.providerId && entry.modelId)
    })
}

function providerFromDocument(document: TomlDocument, id: string): RuntimeTomlProvider {
  const values = sectionValues(document, `providers.${id}`)
  const credentials = sectionValues(document, `providers.${id}.credentials`)
  const endpoint = asString(values.endpoint)
  const command = asString(values.command)
  const credentialType = asString(credentials.type) as RuntimeTomlCredentialType
  return {
    id,
    displayName: asString(values['display-name'], asString(values['provider-name'], id)),
    protocol: asString(values.protocol),
    transportKind: endpoint ? 'endpoint' : command ? 'command' : 'missing',
    endpoint,
    command,
    credentialType: credentialType === 'env' || credentialType === 'file' || credentialType === 'inline'
      ? credentialType
      : 'none',
    credentialKey: asString(credentials.key),
    credentialPath: asString(credentials.path),
    credentialValue: asString(credentials.value),
  }
}

function modelFromDocument(document: TomlDocument, id: string): RuntimeTomlModel {
  const values = sectionValues(document, `models.${id}`)
  return {
    id,
    apiName: asString(values['api-name'], asString(values['model-name'], id)),
    maxContext: asNumber(values['max-context']),
    toolsSupport: asBoolean(values['tools-support']),
    thinkingSupport: asBoolean(values['thinking-support']),
    jsonSupport: typeof values['json-support'] === 'boolean' ? values['json-support'] : null,
    streaming: asBoolean(values.streaming, true),
  }
}

function bindingFromDocument(
  document: TomlDocument,
  entry: { providerId: string; modelId: string; section: string },
): RuntimeTomlBinding {
  const values = sectionValues(document, entry.section)
  return {
    id: `${entry.providerId}.${entry.modelId}`,
    providerId: entry.providerId,
    modelId: entry.modelId,
    isDefault: asBoolean(values['is-default']),
    maxConcurrent: asNumber(values['max-concurrent']),
    keepAlive: asString(values['keep-alive']),
    numCtx: asNumber(values['num-ctx']),
  }
}

export function parseRuntimeTomlEnvironment(sourceText: string): RuntimeTomlEnvironment {
  const document = parseDocument(sourceText)
  const runtimeValues = sectionValues(document, 'runtime')
  const assignmentValues = sectionValues(document, 'runtime.assignments')
  const assignments = Object.fromEntries(
    Object.entries(assignmentValues)
      .filter((entry): entry is [string, string] => typeof entry[1] === 'string'),
  )
  const providers = providerIds(document).map(id => providerFromDocument(document, id))
  const models = modelIds(document).map(id => modelFromDocument(document, id))
  const bindings = bindingSections(document).map(entry => bindingFromDocument(document, entry))
  const warnings: string[] = []
  if (providers.length === 0) warnings.push('providers.* section not found')
  if (models.length === 0) warnings.push('models.* section not found')
  if (bindings.length === 0) warnings.push('provider.model binding section not found')
  return {
    defaultRuntimeId: asString(runtimeValues.default),
    librarianRuntimeId: asString(runtimeValues.librarian),
    crossVerifierRuntimeId: asString(runtimeValues.cross_verifier),
    assignments,
    providers,
    models,
    bindings,
    warnings,
  }
}

function sourceLineCount(sourceText: string): number {
  return sourceText.length === 0 ? 1 : sourceText.split('\n').length
}

function sortedSectionEntries(document: TomlDocument, sectionName: string): Array<[string, TomlScalar]> {
  return Object.entries(sectionValues(document, sectionName)).sort(([left], [right]) =>
    left.localeCompare(right),
  )
}

function runtimeAssignmentsSignature(document: TomlDocument): string {
  return JSON.stringify(sortedSectionEntries(document, 'runtime.assignments'))
}

export function runtimeTomlImpactSummary(
  beforeSourceText: string,
  afterSourceText: string,
): RuntimeTomlImpactSummary {
  const beforeDocument = parseDocument(beforeSourceText)
  const afterDocument = parseDocument(afterSourceText)
  const beforeEnvironment = parseRuntimeTomlEnvironment(beforeSourceText)
  const afterEnvironment = parseRuntimeTomlEnvironment(afterSourceText)

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
    section: { name: sectionName, start, end: nextLines.length },
  }
}

export function setRuntimeTomlKey(
  sourceText: string,
  sectionName: string,
  key: string,
  value: string | number | boolean,
): string {
  const initial = parseDocument(sourceText)
  const ensured = ensureSection([...initial.lines], initial, sectionName)
  const lines = ensured.lines
  const section = ensured.section
  const serialized = serializeValue(value)
  for (let index = section.start + 1; index < section.end; index += 1) {
    const match = keyLineMatch(lines[index] ?? '')
    if (match?.[2] === key) {
      lines[index] = `${match[1] ?? ''}${key}${match[3] ?? ' = '}${serialized}`
      return joinLines(lines)
    }
  }
  lines.splice(section.end, 0, `${key} = ${serialized}`)
  return joinLines(lines)
}

// Read a scalar key from a section as its raw TOML token (inline comment
// stripped, trimmed). Symmetric reader for setRuntimeTomlKey; callers parse the
// token (e.g. Number/=== 'true'). Returns undefined when the section or key is
// absent — never a fabricated default.
export function getRuntimeTomlKey(
  sourceText: string,
  sectionName: string,
  key: string,
): string | undefined {
  const document = parseDocument(sourceText)
  const section = sectionOf(document, sectionName)
  if (!section) return undefined
  for (let index = section.start + 1; index < section.end; index += 1) {
    const match = keyLineMatch(document.lines[index] ?? '')
    if (match?.[2] === key) return stripInlineComment(match[4] ?? '').trim()
  }
  return undefined
}

export function deleteRuntimeTomlKey(sourceText: string, sectionName: string, key: string): string {
  const document = parseDocument(sourceText)
  const section = sectionOf(document, sectionName)
  if (!section) return sourceText
  const lines = [...document.lines]
  for (let index = section.end - 1; index > section.start; index -= 1) {
    const match = keyLineMatch(lines[index] ?? '')
    if (match?.[2] === key) lines.splice(index, 1)
  }
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

export function cascadeDeleteProvider(sourceText: string, providerId: string): string {
  const document = parseDocument(sourceText)
  const env = parseRuntimeTomlEnvironment(sourceText)
  const prefix = `providers.${providerId}`
  const prefixDot = `providers.${providerId}.`
  const bindingPrefixDot = `${providerId}.`
  const sectionsToDelete = document.sections
    .map(s => s.name)
    .filter(name => name === prefix || name.startsWith(prefixDot) || name.startsWith(bindingPrefixDot))
  
  let next = sourceText
  for (const sec of sectionsToDelete) {
    next = deleteRuntimeTomlSection(next, sec)
  }

  // Also remove from runtime defaults/assignments if they reference this provider
  const nextDocument = parseDocument(next)
  const runtimeValues = sectionValues(nextDocument, 'runtime')
  const toDeleteBindings = new Set(env.bindings.filter(b => b.providerId === providerId).map(b => b.id))
  
  if (typeof runtimeValues.default === 'string' && toDeleteBindings.has(runtimeValues.default)) {
    next = deleteRuntimeTomlKey(next, 'runtime', 'default')
  }
  if (typeof runtimeValues.librarian === 'string' && toDeleteBindings.has(runtimeValues.librarian)) {
    next = deleteRuntimeTomlKey(next, 'runtime', 'librarian')
  }
  if (typeof runtimeValues.cross_verifier === 'string' && toDeleteBindings.has(runtimeValues.cross_verifier)) {
    next = deleteRuntimeTomlKey(next, 'runtime', 'cross_verifier')
  }
  
  // Clean up assignments
  const assignments = sectionValues(nextDocument, 'runtime.assignments')
  for (const [key, value] of Object.entries(assignments)) {
    if (typeof value === 'string' && toDeleteBindings.has(value)) {
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
  field: 'display-name' | 'protocol' | 'endpoint' | 'command',
  value: string,
): string {
  const section = `providers.${providerId}`
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
  const section = `providers.${providerId}.credentials`
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
  next = setRuntimeTomlKey(next, section, 'value', value)
  next = deleteRuntimeTomlKey(next, section, 'key')
  return deleteRuntimeTomlKey(next, section, 'path')
}

export function setRuntimeTomlModelField(
  sourceText: string,
  modelId: string,
  field: 'api-name' | 'max-context' | 'tools-support' | 'thinking-support' | 'json-support' | 'streaming',
  value: string | number | boolean | null,
): string {
  if (value === null) return deleteRuntimeTomlKey(sourceText, `models.${modelId}`, field)
  return setRuntimeTomlKey(sourceText, `models.${modelId}`, field, value)
}

export function setRuntimeTomlBindingField(
  sourceText: string,
  runtimeId: string,
  field: 'is-default' | 'max-concurrent' | 'keep-alive' | 'num-ctx',
  value: string | number | boolean | null,
): string {
  if (value === null) return deleteRuntimeTomlKey(sourceText, runtimeId, field)
  return setRuntimeTomlKey(sourceText, runtimeId, field, value)
}

// Closed set mirroring lib/runtime/runtime_toml.ml's api_format_of_protocol —
// any other string fails runtime.toml validation on save (Runtime.save_config_text
// re-parses via materialize_config). Kept here, not hardcoded in the form, so
// the add-provider UI can never offer a protocol the backend will reject.
export const RUNTIME_TOML_PROTOCOLS = [
  'openai-compatible-http',
  'ollama-http',
  'openai-compatible-cli',
  'messages-http',
  'messages-cli',
] as const

export type RuntimeTomlProtocol = (typeof RUNTIME_TOML_PROTOCOLS)[number]

// runtime.toml ids become TOML table headers ([providers.<id>], [models.<id>],
// and the binding pin [<providerId>.<modelId>]). parseDocument's section regex
// and bindingSections' 2-part split both assume an id has no '.', so a bare-key
// -safe charset is required, not just non-empty.
const RUNTIME_TOML_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]*$/

export function isValidRuntimeTomlIdFormat(id: string): boolean {
  return RUNTIME_TOML_ID_PATTERN.test(id)
}

export function isReservedRuntimeTomlId(id: string): boolean {
  return RESERVED_TOP_LEVEL.has(id)
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
  const ensured = ensureSection([...document.lines], document, `${providerId}.${modelId}`)
  return joinLines(ensured.lines)
}
