import { TRUST_DISPOSITIONS, type TrustDisposition } from '../types'

const TRUST_DISPOSITION_SET: ReadonlySet<string> = new Set(TRUST_DISPOSITIONS)

function isTrustDisposition(value: string): value is TrustDisposition {
  return TRUST_DISPOSITION_SET.has(value)
}

export function asTrustDisposition(value: unknown): TrustDisposition | null {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return isTrustDisposition(trimmed) ? trimmed : null
}
