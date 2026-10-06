/** The package schema subset accepted by Lane_addon_action.schema_node.
 * Editing keeps absent fields and invalid numeric text distinct from values. */
export type Json = null | boolean | number | string | Json[] | { [key: string]: Json }
export type BindingSchema = {
  type: 'object' | 'array' | 'string' | 'integer' | 'number' | 'boolean'
  title?: string; description?: string; properties?: Map<string, BindingSchema>; required: Set<string>
  items?: BindingSchema; oneOf?: BindingSchema[]; choices?: Json[]
  constant: boolean; minimum?: number; maximum?: number; exclusiveMinimum?: number; exclusiveMaximum?: number
  minLength?: number; maxLength?: number; minItems?: number; maxItems?: number
}
export type BindingInput =
  | { kind: 'unset' }
  | { kind: 'text'; text: string }
  | { kind: 'boolean'; value: boolean }
  | { kind: 'choice'; index: number }
  | { kind: 'object'; fields: Map<string, BindingInput> }
  | { kind: 'array'; items: BindingInput[] }
  | { kind: 'union'; selected: number | null; branches: BindingInput[] }
export const unset: BindingInput = { kind: 'unset' }
const record = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value)
const keys = new Set(['type', 'properties', 'required', 'additionalProperties', 'items', 'enum', 'const',
  'description', 'title', 'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'minLength', 'maxLength', 'minItems', 'maxItems', 'oneOf'])

function json(value: unknown): Json {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') return value
  if (typeof value === 'number' && Number.isFinite(value) && (!Number.isInteger(value) || Number.isSafeInteger(value))) return value
  if (Array.isArray(value)) return value.map(json)
  if (record(value)) return Object.fromEntries(Object.entries(value).map(([key, value]) => [key, json(value)]))
  throw new Error('Schema contains a value this form cannot represent exactly.')
}
export function parseBindingSchema(value: unknown): BindingSchema {
  if (!record(value) || Object.keys(value).some(key => !keys.has(key))) throw new Error('Unsupported package schema keyword or shape.')
  const type = value.type
  if (type !== 'object' && type !== 'array' && type !== 'string' && type !== 'integer' && type !== 'number' && type !== 'boolean') {
    throw new Error('Unsupported package schema type.')
  }
  const result: BindingSchema = { type, constant: Object.hasOwn(value, 'const'), required: new Set() }
  for (const key of ['title', 'description'] as const) {
    if (Object.hasOwn(value, key)) {
      if (typeof value[key] !== 'string') throw new Error(`${key} must be text.`)
      result[key] = value[key]
    }
  }
  for (const key of ['minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'minLength', 'maxLength', 'minItems', 'maxItems'] as const) {
    if (!Object.hasOwn(value, key)) continue
    const bound = value[key]
    if (typeof bound !== 'number' || !Number.isFinite(bound)) throw new Error(`Invalid ${key}.`)
    if (['minLength', 'maxLength', 'minItems', 'maxItems'].includes(key) && (!Number.isSafeInteger(bound) || bound < 0)) throw new Error(`Invalid ${key}.`)
    result[key] = bound
  }
  if (Object.hasOwn(value, 'enum')) {
    if (!Array.isArray(value.enum)) throw new Error('enum must be an array.')
    result.choices = value.enum.map(json)
  }
  if (result.constant) {
    const constant = json(value.const)
    if (result.choices && !result.choices.some(choice => same(choice, constant))) throw new Error('Schema const is excluded by its enum.')
    result.choices = [constant]
  }
  if (Object.hasOwn(value, 'oneOf')) {
    if (!Array.isArray(value.oneOf) || value.oneOf.length === 0) throw new Error('oneOf must have alternatives.')
    result.oneOf = value.oneOf.map(parseBindingSchema)
  }
  if (type === 'object') {
    if (result.oneOf && !Object.hasOwn(value, 'properties')) {
      if (Object.hasOwn(value, 'required') || Object.hasOwn(value, 'additionalProperties')) throw new Error('Object union constraints require declared properties.')
    } else {
      if (!record(value.properties) || value.additionalProperties !== false) throw new Error('Package objects require properties and additionalProperties=false.')
      result.properties = new Map(Object.entries(value.properties).map(([key, schema]) => [key, parseBindingSchema(schema)]))
      if (value.required !== undefined) {
        if (!Array.isArray(value.required) || value.required.some(key => typeof key !== 'string' || !result.properties!.has(key))
          || new Set(value.required).size !== value.required.length) throw new Error('required must name distinct declared fields.')
        result.required = new Set(value.required as string[])
      }
    }
  }
  if (type === 'array') result.items = parseBindingSchema(value.items)
  return result
}

export function branchSchema(schema: BindingSchema, index: number): BindingSchema {
  const branch = schema.oneOf?.[index]
  if (!branch) throw new Error('Choose a schema alternative.')
  // Rendering combines declared fields; validation retains BOTH contracts and
  // checks exactly-one matching branch, rather than treating oneOf as anyOf.
  return { ...schema, ...branch, oneOf: branch.oneOf,
    properties: schema.properties || branch.properties ? new Map([...schema.properties ?? [], ...branch.properties ?? []]) : undefined,
    required: new Set([...schema.required, ...branch.required]) }
}
export function bindingAlternativeLabel(schema: BindingSchema, index: number): string {
  if (schema.title?.trim()) return schema.title
  if (schema.description?.trim()) return schema.description
  const constants = [...schema.properties ?? []].flatMap(([key, child]) => child.constant
    ? [`${key}: ${JSON.stringify(child.choices![0])}`] : [])
  return constants.length ? constants.join(' · ') : `Alternative ${index + 1}`
}
export function initialBindingInput(schema: BindingSchema, required = true): BindingInput {
  if (!required) return unset
  if (schema.choices) return schema.constant ? { kind: 'choice', index: 0 } : unset
  if (schema.oneOf) return { kind: 'union', selected: null, branches: schema.oneOf.map((_, index) => initialBindingInput(branchSchema(schema, index))) }
  if (schema.type === 'object') return { kind: 'object', fields: new Map([...schema.properties ?? []].map(([key, child]) => [key, initialBindingInput(child, schema.required.has(key))])) }
  if (schema.type === 'array') return { kind: 'array', items: [] }
  return unset
}
function same(a: Json, b: Json): boolean {
  if (a === b) return true
  if (Array.isArray(a)) return Array.isArray(b) && a.length === b.length && a.every((item, i) => same(item, b[i]!))
  return record(a) && record(b) && Object.keys(a).length === Object.keys(b).length
    && Object.entries(a).every(([key, value]) => Object.hasOwn(b, key) && same(value as Json, b[key] as Json))
}

export function bindingErrors(schema: BindingSchema, value: Json, name = 'binding'): string[] {
  const errors: string[] = []
  if (schema.choices && !schema.choices.some(choice => same(choice, value))) errors.push(`${name}: choose an advertised value.`)
  if (schema.oneOf && schema.oneOf.filter(branch => bindingErrors(branch, value, name).length === 0).length !== 1) errors.push(`${name}: must match exactly one alternative.`)
  switch (schema.type) {
    case 'object':
      if (!record(value)) return [...errors, `${name}: expected an object.`]
      if (schema.properties) {
        for (const key of schema.required) if (!Object.hasOwn(value, key)) errors.push(`${name}.${key}: required.`)
        for (const [key, child] of Object.entries(value)) {
          const property = schema.properties.get(key)
          if (!property) errors.push(`${name}.${key}: unknown field.`)
          else errors.push(...bindingErrors(property, child as Json, `${name}.${key}`))
        }
      }
      break
    case 'array':
      if (!Array.isArray(value)) return [...errors, `${name}: expected an array.`]
      if (schema.minItems !== undefined && value.length < schema.minItems) errors.push(`${name}: needs at least ${schema.minItems} items.`)
      if (schema.maxItems !== undefined && value.length > schema.maxItems) errors.push(`${name}: allows at most ${schema.maxItems} items.`)
      value.forEach((child, i) => errors.push(...bindingErrors(schema.items!, child, `${name}[${i + 1}]`)))
      break
    case 'string':
      if (typeof value !== 'string') return [...errors, `${name}: expected text.`]
      if (schema.minLength !== undefined && [...value].length < schema.minLength) errors.push(`${name}: needs at least ${schema.minLength} characters.`)
      if (schema.maxLength !== undefined && [...value].length > schema.maxLength) errors.push(`${name}: allows at most ${schema.maxLength} characters.`)
      break
    case 'boolean': if (typeof value !== 'boolean') errors.push(`${name}: choose true or false.`); break
    case 'integer': case 'number':
      if (typeof value !== 'number' || !Number.isFinite(value) || schema.type === 'integer' && !Number.isSafeInteger(value)) return [...errors, `${name}: expected ${schema.type}.`]
      if (schema.minimum !== undefined && value < schema.minimum) errors.push(`${name}: minimum ${schema.minimum}.`)
      if (schema.maximum !== undefined && value > schema.maximum) errors.push(`${name}: maximum ${schema.maximum}.`)
      if (schema.exclusiveMinimum !== undefined && value <= schema.exclusiveMinimum) errors.push(`${name}: must exceed ${schema.exclusiveMinimum}.`)
      if (schema.exclusiveMaximum !== undefined && value >= schema.exclusiveMaximum) errors.push(`${name}: must be below ${schema.exclusiveMaximum}.`)
      break
  }
  return errors
}
export function readBindingInput(schema: BindingSchema, input: BindingInput, name = 'binding'): Json {
  let value: Json
  switch (input.kind) {
    case 'unset': throw new Error(`${name}: required value is not set.`)
    case 'choice': {
      const choice = schema.choices?.[input.index]
      if (choice === undefined) throw new Error(`${name}: choose an advertised value.`)
      value = choice; break
    }
    case 'union':
      if (input.selected === null || !input.branches[input.selected]) throw new Error(`${name}: choose an alternative.`)
      value = readBindingInput(branchSchema(schema, input.selected), input.branches[input.selected]!, name); break
    case 'object': value = Object.fromEntries([...input.fields].filter(([, child]) => child.kind !== 'unset').map(([key, child]) => {
      const property = schema.properties?.get(key)
      if (!property) throw new Error(`${name}.${key}: unknown field.`)
      return [key, readBindingInput(property, child, `${name}.${key}`)]
    })); break
    case 'array': value = input.items.map((child, index) => readBindingInput(schema.items!, child, `${name}[${index + 1}]`)); break
    case 'boolean': value = input.value; break
    case 'text':
      if (schema.type === 'string') value = input.text
      else {
        // JSON number syntax accepts decimal/exponent notation but not hex,
        // whitespace-only text, Infinity or a partially typed number.
        try { value = json(JSON.parse(input.text)) } catch { throw new Error(`${name}: enter a complete finite number.`) }
        if (typeof value !== 'number') throw new Error(`${name}: enter a number.`)
      }
      break
  }
  const errors = bindingErrors(schema, value, name)
  if (errors.length) throw new Error(errors.join(' '))
  return value
}
export function inputFromValue(schema: BindingSchema, value: Json): BindingInput {
  if (schema.choices) {
    const index = schema.choices.findIndex(choice => same(choice, value))
    if (index < 0) throw new Error('The selected source is not supported by this package field.')
    return { kind: 'choice', index }
  }
  if (schema.oneOf) {
    const matches = schema.oneOf.flatMap((branch, index) => bindingErrors(branch, value).length === 0 ? [index] : [])
    if (matches.length !== 1) throw new Error('The value must match exactly one alternative.')
    const selected = matches[0]!
    return { kind: 'union', selected, branches: schema.oneOf.map((_, index) => index === selected
      ? inputFromValue(branchSchema(schema, index), value) : initialBindingInput(branchSchema(schema, index))) }
  }
  if (schema.type === 'object' && record(value)) return { kind: 'object', fields: new Map([...schema.properties ?? []].map(([key, child]) =>
    [key, Object.hasOwn(value, key) ? inputFromValue(child, value[key] as Json) : initialBindingInput(child, schema.required.has(key))])) }
  if (schema.type === 'array' && Array.isArray(value)) return { kind: 'array', items: value.map(child => inputFromValue(schema.items!, child)) }
  if (typeof value === 'boolean') return { kind: 'boolean', value }
  return { kind: 'text', text: typeof value === 'string' ? value : JSON.stringify(value) }
}
function tomlString(value: string): string {
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i)
    if (code >= 0xd800 && code <= 0xdbff) {
      const next = value.charCodeAt(++i)
      if (!(next >= 0xdc00 && next <= 0xdfff)) throw new Error('Text contains an incomplete Unicode character.')
    } else if (code >= 0xdc00 && code <= 0xdfff) throw new Error('Text contains an incomplete Unicode character.')
  }
  return JSON.stringify(value).replace(/\u007f/g, '\\u007f')
}
function tomlValue(value: Json): string {
  if (value === null) throw new Error('TOML cannot represent null.')
  if (typeof value === 'string') return tomlString(value)
  if (typeof value === 'number') {
    if (!Number.isFinite(value) || Number.isInteger(value) && !Number.isSafeInteger(value)) throw new Error('Number cannot be represented exactly.')
    return Object.is(value, -0) ? '-0.0' : String(value)
  }
  if (typeof value === 'boolean') return String(value)
  if (Array.isArray(value)) return `[${value.map(tomlValue).join(', ')}]`
  return `{ ${Object.entries(value).map(([key, child]) => `${tomlString(key)} = ${tomlValue(child)}`).join(', ')} }`
}
export function packageDeclaration(id: string, runId: string, manifestPath: string, binding: Json): string {
  if (!id.trim() || !runId.trim()) throw new Error('Installation ID and Run ID are required.')
  return `enabled = true\nid = ${tomlString(id)}\nrun_id = ${tomlString(runId)}\nmanifest_path = ${tomlString(manifestPath)}\nbinding = ${tomlValue(binding)}\n`
}
