import { signal } from '@preact/signals'
import type { OperatorSnapshot } from './types'

/** Controlled rows for presentation tests; authority tests use real HTTP/SSE. */
export const operatorSnapshotFixture = signal<OperatorSnapshot | null>(null)
