import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { getStaticTOMLValue, parseTOML } from 'toml-eslint-parser'
import { bindingErrors, initialBindingInput, inputFromValue, packageDeclaration, parseBindingSchema, readBindingInput } from './lane-binding-form'

const object = (properties: Record<string, unknown>, required = Object.keys(properties)) => ({ type: 'object', properties, required, additionalProperties: false })
describe('Package schema inputs and declaration preparation', () => {
  it.each(['fusion-report', 'fusion-compute', 'fusion-results', 'quiz-grader', 'quiz-questions', 'dos-world', 'output-statistics', 'value-difference', 'wkbl-score-runs'])(
    'accepts the real %s package schema', name => {
      const source = readFileSync(resolve(process.cwd(), '..', 'addons', name, 'lane.toml'), 'utf8')
      // Repository-authored fixtures only; generated special-key data below is
      // checked through the AST rather than the parser's object evaluator.
      const manifest = getStaticTOMLValue(parseTOML(source)) as { interface: { binding_schema: string } }
      expect(parseBindingSchema(JSON.parse(manifest.interface.binding_schema)).type).toBe('object')
    })
  it('keeps false, zero, empty arrays and absent optional objects distinct', () => {
    const schema = parseBindingSchema(object({ enabled: { type: 'boolean' }, count: { type: 'integer', minimum: 0 },
      items: { type: 'array', items: { type: 'string' } }, optional: object({ mode: { type: 'string', const: 'safe' } }) }, ['enabled', 'count', 'items']))
    const input = inputFromValue(schema, { enabled: false, count: 0, items: [] })
    const binding = readBindingInput(schema, input)
    expect(binding).toEqual({ enabled: false, count: 0, items: [] })
    const source = packageDeclaration('a', 'run', '/packages/a/lane.toml', binding)
    expect(getStaticTOMLValue(parseTOML(source))).toEqual({ enabled: true, id: 'a', run_id: 'run', manifest_path: '/packages/a/lane.toml', binding })
  })
  it('keeps incomplete numbers editable and rejects them at review', () => {
    const schema = parseBindingSchema({ type: 'number' })
    for (const text of ['1e', '', '0x10', 'null', 'true', 'Infinity', '9007199254740993']) {
      expect(() => readBindingInput(schema, { kind: 'text', text })).toThrow()
    }
    expect(readBindingInput(schema, { kind: 'text', text: '1.5e2' })).toBe(150)
  })
  it('retains root/branch constraints and requires exactly one alternative', () => {
    const schema = parseBindingSchema({ type: 'object', oneOf: [object({ kind: { type: 'string', const: 'file' }, path: { type: 'string', minLength: 1 } }),
      object({ kind: { type: 'string', const: 'port' }, installation_id: { type: 'string', minLength: 1 } })] })
    expect(() => readBindingInput(schema, initialBindingInput(schema))).toThrow(/alternative/)
    expect(readBindingInput(schema, inputFromValue(schema, { kind: 'port', installation_id: 'producer' }))).toEqual({ kind: 'port', installation_id: 'producer' })
    expect(bindingErrors(schema, { kind: 'file', path: '' }).length).toBeGreaterThan(0)
    const ambiguous = parseBindingSchema({ type: 'number', minimum: 5, oneOf: [{ type: 'number' }, { type: 'integer' }] })
    expect(bindingErrors(ambiguous, 8).join(' ')).toMatch(/exactly one/)
    expect(bindingErrors(ambiguous, 4.5).join(' ')).toMatch(/minimum/)
    expect(bindingErrors(ambiguous, 5.5)).toEqual([])
  })
  it('uses Unicode character counts and escapes TOML controls without losing text', () => {
    const schema = parseBindingSchema({ type: 'string', minLength: 2, maxLength: 2 })
    expect(readBindingInput(schema, { kind: 'text', text: '한😀' })).toBe('한😀')
    const binding = { text: 'quotes " and newline\ncontrol\u007f' }
    expect(getStaticTOMLValue(parseTOML(packageDeclaration('unicode', 'run', '/a', binding)))).toMatchObject({ binding })
    // An actual DEL is emitted as the six-character escape; the literal
    // backslash-u text is a different value and must round-trip unchanged.
    const del = packageDeclaration('del', 'run', '/a', { text: '\u007f' })
    expect(del).toContain('"\\u007f"')
    expect(del).not.toContain('\u007f')
    const literal = { text: 'literal \\u007f stays text' }
    expect(getStaticTOMLValue(parseTOML(packageDeclaration('literal', 'run', '/a', literal)))).toMatchObject({ binding: literal })
    expect(() => packageDeclaration('bad', 'run', '/a', { text: '\ud800' })).toThrow(/Unicode/)
  })
  it('preserves prototype-like keys as own data without inherited field lookups', () => {
    const properties = JSON.parse('{"__proto__":{"type":"string"},"constructor":{"type":"string"}}')
    const schema = parseBindingSchema(object(properties))
    const binding = readBindingInput(schema, inputFromValue(schema, JSON.parse('{"__proto__":"literal","constructor":"name"}')))
    expect(Object.hasOwn(binding as object, '__proto__')).toBe(true)
    expect(Object.getPrototypeOf(binding)).toBe(Object.prototype)
    const source = packageDeclaration('special', 'run', '/a', binding)
    expect(source).toContain('"__proto__" = "literal"')
    expect(() => parseTOML(source)).not.toThrow()
    expect(Object.prototype).not.toHaveProperty('literal')
  })
  it('rejects unsupported schema shapes instead of making a pretend form', () => {
    for (const schema of [{ type: 'object' }, { type: 'array' }, { type: 'string', pattern: 'guess' }, { type: 'integer', minItems: -1 },
      { type: 'string', const: 'a', enum: ['b'] }, { type: 'object', oneOf: [] }]) expect(() => parseBindingSchema(schema)).toThrow()
  })
})
