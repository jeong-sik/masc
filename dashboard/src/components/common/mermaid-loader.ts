import type { Mermaid } from 'mermaid'

export type MermaidApi = Mermaid

let mermaidPromise: Promise<MermaidApi> | null = null

export function loadMermaid(): Promise<MermaidApi> {
  if (!mermaidPromise) {
    mermaidPromise = import('mermaid')
      .then(module => module.default)
      .catch(err => {
        mermaidPromise = null
        throw err
      })
  }
  return mermaidPromise
}
