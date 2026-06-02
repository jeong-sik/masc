import { signal } from '@preact/signals'

export const selectedNodeId = signal<string | null>(null)
export const highlightedAgentId = signal<string | null>(null)
