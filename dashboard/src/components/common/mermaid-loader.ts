import type MermaidDefault from 'mermaid'

export type MermaidApi = typeof MermaidDefault

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
