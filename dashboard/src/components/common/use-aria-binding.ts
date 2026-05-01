// use-aria-binding.ts — ARIA ID auto-linking hook
//
// Kimi design system sec01 1.2.2: useId-based ARIA automatic connection.
// Generates paired IDs for trigger/content/title/description ARIA linking.

import { useId } from 'preact/hooks'

export interface ARIABinding {
  triggerId: string
  contentId: string
  titleId: string
  descriptionId: string
}

export function useARIABinding(): ARIABinding {
  const id = useId()
  return {
    triggerId: `${id}-trigger`,
    contentId: `${id}-content`,
    titleId: `${id}-title`,
    descriptionId: `${id}-description`,
  }
}
