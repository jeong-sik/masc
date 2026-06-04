export const scopeMarkerDescriptions = {
  "_density-scope": "scope marker",
  "_motion-scope": "scope marker",
} as const

export type ScopeMarkerToken = keyof typeof scopeMarkerDescriptions
