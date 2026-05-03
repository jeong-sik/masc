function truthyEnvFlag(value: unknown): boolean {
  if (typeof value === 'string') {
    const normalized = value.trim().toLowerCase()
    return normalized !== '' && normalized !== '0' && normalized !== 'false'
  }
  return value === true
}

export function runningUnderVitest(): boolean {
  return import.meta.env?.MODE === 'test'
    || truthyEnvFlag(import.meta.env?.VITEST)
    || truthyEnvFlag(typeof process !== 'undefined' ? process.env.VITEST : undefined)
}
