import { signal } from '@preact/signals'
import type { Task } from '../../types'

export const selectedTask = signal<Task | null>(null)
