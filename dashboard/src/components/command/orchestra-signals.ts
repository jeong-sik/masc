import { signal } from '@preact/signals'

export const orchestraSelection = signal<string | null>(null)
export const orchestraDensity = signal<'balanced' | 'compact'>('compact')
export const orchestraCamera = signal({ zoom: 1, panX: 0, panY: 0 })
export const orchestraDragging = signal(false)
export const orchestraHasInteracted = signal(false)
