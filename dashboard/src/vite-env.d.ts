/// <reference types="vite/client" />

declare module '*.css'

declare module 'culori' {
  export function oklch(value: string): unknown
  export function differenceEuclidean(
    mode: string
  ): (left: unknown, right: unknown) => number
}
