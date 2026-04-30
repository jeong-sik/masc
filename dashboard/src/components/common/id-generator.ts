// id-generator.ts — SSR-safe ID generation for ARIA bindings
//
// Kimi design system sec01 1.2.2 / sec08 8.1.1: framework-agnostic ID
// generator with server-client consistency. Preact's useId() is the
// preferred runtime source, but a fallback counter ensures standalone
// usage in tests or non-Preact contexts.

let _globalCounter = 0

function nextId(): string {
  _globalCounter += 1
  return `masc-${_globalCounter}`
}

/** Reset the global counter — useful only in tests. */
export function resetIdCounter(): void {
  _globalCounter = 0
}

/** Generate a single unique ID. */
export function generateId(): string {
  return nextId()
}

/** ARIA binding ids for compound components (trigger ↔ content). */
export interface ARIABinding {
  id: string
  triggerId: string
  contentId: string
  titleId: string
  descriptionId: string
}

/** Create a full set of ARIA binding ids from a base id. */
export function createARIABinding(baseId?: string): ARIABinding {
  const id = baseId ?? nextId()
  return {
    id,
    triggerId: `${id}-trigger`,
    contentId: `${id}-content`,
    titleId: `${id}-title`,
    descriptionId: `${id}-description`,
  }
}
