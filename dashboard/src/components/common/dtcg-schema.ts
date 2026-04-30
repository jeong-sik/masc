// dtcg-schema.ts — DTCG v1 (2025.10) type definitions
//
// Kimi design system sec04 4.1: W3C DTCG Spec v1 compliant token schema.

export type DTCGTokenType =
  | 'color'
  | 'dimension'
  | 'fontFamily'
  | 'fontWeight'
  | 'duration'
  | 'cubicBezier'
  | 'number'
  | 'shadow'
  | 'transition'

export interface DTCGToken {
  $value: unknown
  $type: DTCGTokenType
  $description?: string
  $extensions?: Record<string, unknown>
}

export interface DTCGTokenGroup {
  [key: string]: DTCGToken | DTCGTokenGroup
  $type?: DTCGTokenType
  $description?: string
}

export type DTCGShadowValue = {
  color: string
  offsetX: string
  offsetY: string
  blur: string
  spread: string
}

export type DTCGTransitionValue = {
  duration: number
  delay?: number
  timingFunction: [number, number, number, number]
}
