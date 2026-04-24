import { signal } from '@preact/signals'

export const dashboardWsConnected = signal(false)
export const dashboardWsReady = signal(false)
export const dashboardWsLastError = signal<string | null>(null)
export const dashboardWsLastSeq = signal(0)
