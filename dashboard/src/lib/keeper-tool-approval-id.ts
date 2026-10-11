import { validate as isUuid, version as uuidVersion } from 'uuid'

/** Canonical server approval admission identity; never a provider tool-call ID. */
export function decodeKeeperToolApprovalId(value: unknown): string | null {
  return typeof value === 'string' && isUuid(value) && uuidVersion(value) === 7
    ? value.toLowerCase()
    : null
}
