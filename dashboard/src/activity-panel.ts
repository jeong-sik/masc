import { signal } from '@preact/signals'

export const activityPanelOpen = signal(false)

export function openActivityPanel(): void {
  activityPanelOpen.value = true
}

export function closeActivityPanel(): void {
  activityPanelOpen.value = false
}

export function toggleActivityPanel(): void {
  activityPanelOpen.value = !activityPanelOpen.value
}
