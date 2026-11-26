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

export function expectRequiredArrayField<T>(
  record: Record<string, unknown>,
  field: string,
  context: string,
): readonly T[] {
  const value = record[field]
  if (!Array.isArray(value)) {
    throw new Error(`${context}: "${field}" 필드는 필수 배열입니다 (${describeWireType(value)} 수신).`)
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

export function expectRequiredRecordField(
  record: Record<string, unknown>,
  field: string,
  context: string,
): Record<string, unknown> {
  const value = record[field]
  if (!isJsonRecord(value)) {
    throw new Error(`${context}: "${field}" 필드는 필수 객체입니다 (${describeWireType(value)} 수신).`)
  }
  return value
}

export function expectRequiredStringField(
  record: Record<string, unknown>,
  field: string,
  context: string,
): string {
  const value = record[field]
  if (typeof value !== 'string') {
    throw new Error(`${context}: "${field}" 필드는 필수 문자열입니다 (${describeWireType(value)} 수신).`)
  }
  return value
}

export function expectRequiredNumberField(
  record: Record<string, unknown>,
  field: string,
  context: string,
): number {
  const value = record[field]
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Error(`${context}: "${field}" 필드는 필수 숫자입니다 (${describeWireType(value)} 수신).`)
  }
  return value
}

export function expectRecordElements<T>(
  items: readonly unknown[],
  field: string,
  context: string,
): readonly T[] {
  for (let i = 0; i < items.length; i += 1) {
    const item = items[i]
    if (!isJsonRecord(item)) {
      throw new Error(`${context}: "${field}[${i}]" 항목은 객체여야 합니다 (${describeWireType(item)} 수신).`)
    }
  }
  return items as readonly T[]
}

export function expectStringElements(
  items: readonly unknown[],
  field: string,
  context: string,
): readonly string[] {
  for (let i = 0; i < items.length; i += 1) {
    const item = items[i]
    if (typeof item !== 'string') {
      throw new Error(`${context}: "${field}[${i}]" 항목은 문자열이어야 합니다 (${describeWireType(item)} 수신).`)
    }
  }
  return items as readonly string[]
}

export function expectOptionalRecordArrayField<T>(
  record: Record<string, unknown>,
  field: string,
  context: string,
): readonly T[] {
  return expectRecordElements<T>(expectOptionalArrayField<unknown>(record, field, context), field, context)
}

export function expectOptionalStringArrayField(
  record: Record<string, unknown>,
  field: string,
  context: string,
): readonly string[] {
  return expectStringElements(expectOptionalArrayField<unknown>(record, field, context), field, context)
}
