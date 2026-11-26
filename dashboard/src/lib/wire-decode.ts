/**
 * Strict wire-boundary helpers that distinguish omitted optional fields
 * (`undefined`) from malformed non-array / non-record payloads (`"oops"`,
 * `{}`, `123`, `null`, etc.) so schema drift surfaces as an explicit decode
 * error instead of being silently coerced to an empty collection.
 */

export function isJsonRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function describeWireType(value: unknown): string {
  if (value === null) return 'null'
  if (Array.isArray(value)) return 'array'
  return typeof value
}

export function expectWireRecord(raw: unknown, context: string): Record<string, unknown> {
  if (!isJsonRecord(raw)) {
    throw new Error(`${context}: JSON 객체가 필요합니다 (${describeWireType(raw)} 수신).`)
  }
  return raw
}

export function expectOptionalArrayField<T>(
  record: Record<string, unknown>,
  field: string,
  context: string,
): readonly T[] {
  const value = record[field]
  if (value === undefined) return []
  if (!Array.isArray(value)) {
    throw new Error(`${context}: "${field}" 필드는 배열이어야 합니다 (${describeWireType(value)} 수신).`)
  }
  return value as readonly T[]
}

export function expectOptionalRecordField(
  record: Record<string, unknown>,
  field: string,
  context: string,
): Record<string, unknown> {
  const value = record[field]
  if (value === undefined) return {}
  if (!isJsonRecord(value)) {
    throw new Error(`${context}: "${field}" 필드는 객체여야 합니다 (${describeWireType(value)} 수신).`)
  }
  return value
}
