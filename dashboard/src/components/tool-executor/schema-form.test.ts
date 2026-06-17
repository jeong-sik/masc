// @vitest-environment happy-dom
import { describe, it, expect } from 'vitest'
import { render, h } from 'preact'
import { buildDefaults, stripEmptyOptionals, validateRequired, SchemaForm } from './schema-form'
import type { JsonSchema } from '../../types/json-schema'

// ================================================================
// buildDefaults
// ================================================================

describe('buildDefaults', () => {
  it('returns empty object for schema without properties', () => {
    const schema: JsonSchema = { type: 'object' }
    expect(buildDefaults(schema)).toEqual({})
  })

  it('extracts default values', () => {
    const schema: JsonSchema = {
      type: 'object',
      properties: {
        name: { type: 'string', default: 'world' },
        count: { type: 'integer', default: 42 },
      },
    }
    expect(buildDefaults(schema)).toEqual({ name: 'world', count: 42 })
  })

  it('skips properties without defaults', () => {
    const schema: JsonSchema = {
      type: 'object',
      properties: {
        name: { type: 'string' },
        count: { type: 'integer', default: 0 },
      },
    }
    expect(buildDefaults(schema)).toEqual({ count: 0 })
  })

  it('returns empty for empty properties', () => {
    const schema: JsonSchema = {
      type: 'object',
      properties: {},
    }
    expect(buildDefaults(schema)).toEqual({})
  })
})

// ================================================================
// stripEmptyOptionals
// ================================================================

describe('stripEmptyOptionals', () => {
  const schema: JsonSchema = {
    type: 'object',
    required: ['name'],
    properties: {
      name: { type: 'string' },
      bio: { type: 'string' },
      tags: { type: 'array', items: { type: 'string' } },
    },
  }

  it('keeps required fields even when empty', () => {
    const result = stripEmptyOptionals({ name: '' }, schema)
    expect(result).toEqual({ name: '' })
  })

  it('keeps required fields with value', () => {
    const result = stripEmptyOptionals({ name: 'test' }, schema)
    expect(result).toEqual({ name: 'test' })
  })

  it('strips null optional fields', () => {
    const result = stripEmptyOptionals({ name: 'test', bio: null }, schema)
    expect(result).toEqual({ name: 'test' })
  })

  it('strips undefined optional fields', () => {
    const result = stripEmptyOptionals({ name: 'test', bio: undefined }, schema)
    expect(result).toEqual({ name: 'test' })
  })

  it('strips empty string optional fields', () => {
    const result = stripEmptyOptionals({ name: 'test', bio: '' }, schema)
    expect(result).toEqual({ name: 'test' })
  })

  it('strips empty array optional fields', () => {
    const result = stripEmptyOptionals({ name: 'test', tags: [] }, schema)
    expect(result).toEqual({ name: 'test' })
  })

  it('keeps non-empty optional fields', () => {
    const result = stripEmptyOptionals({ name: 'test', bio: 'hello' }, schema)
    expect(result).toEqual({ name: 'test', bio: 'hello' })
  })

  it('keeps non-empty array optional fields', () => {
    const result = stripEmptyOptionals({ name: 'test', tags: ['a'] }, schema)
    expect(result).toEqual({ name: 'test', tags: ['a'] })
  })

  it('handles schema with no required fields', () => {
    const schemaNoRequired: JsonSchema = {
      type: 'object',
      properties: { name: { type: 'string' } },
    }
    const result = stripEmptyOptionals({ name: '' }, schemaNoRequired)
    expect(result).toEqual({})
  })
})

// ================================================================
// validateRequired
// ================================================================

describe('validateRequired', () => {
  const schema: JsonSchema = {
    type: 'object',
    required: ['name', 'email'],
    properties: {
      name: { type: 'string' },
      email: { type: 'string' },
    },
  }

  it('returns empty array when all required present', () => {
    expect(validateRequired({ name: 'test', email: 'a@b.com' }, schema)).toEqual([])
  })

  it('returns missing required fields', () => {
    expect(validateRequired({ name: 'test' }, schema)).toEqual(['email'])
  })

  it('returns all missing when values empty', () => {
    expect(validateRequired({}, schema)).toEqual(['name', 'email'])
  })

  it('reports undefined as missing', () => {
    expect(validateRequired({ name: 'test', email: undefined }, schema)).toEqual(['email'])
  })

  it('reports null as missing', () => {
    expect(validateRequired({ name: 'test', email: null }, schema)).toEqual(['email'])
  })

  it('reports empty string as missing', () => {
    expect(validateRequired({ name: 'test', email: '' }, schema)).toEqual(['email'])
  })

  it('returns empty for schema with no required', () => {
    const schemaNoReq: JsonSchema = { type: 'object', properties: { name: { type: 'string' } } }
    expect(validateRequired({}, schemaNoReq)).toEqual([])
  })
})

// ================================================================
// Rendering / v2 markers
// ================================================================

describe('SchemaForm rendering', () => {
  it('renders v2-lab-panel on the root and v2-lab-row on each field', () => {
    const schema: JsonSchema = {
      type: 'object',
      required: ['name'],
      properties: {
        name: { type: 'string' },
        count: { type: 'integer' },
      },
    }
    const container = document.createElement('div')
    render(h(SchemaForm, { schema, values: {}, onChange: () => {} }), container)
    expect(container.querySelector('.v2-lab-panel')).not.toBeNull()
    expect(container.querySelectorAll('.v2-lab-row').length).toBe(2)
  })

  it('renders v2-lab-card when the schema has no parameters', () => {
    const schema: JsonSchema = { type: 'object' }
    const container = document.createElement('div')
    render(h(SchemaForm, { schema, values: {}, onChange: () => {} }), container)
    expect(container.querySelector('.v2-lab-card')).not.toBeNull()
    expect(container.textContent).toContain('파라미터가 없습니다')
  })
})
