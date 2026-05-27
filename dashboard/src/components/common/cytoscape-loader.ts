import type cytoscape from 'cytoscape'

/**
 * Cytoscape singleton lazy-loader.
 *
 * `git-graph-view.ts` and `common/cytoscape-fsm.ts` both shipped the
 * same three-part pattern locally: a `CyCore` type alias, a
 * module-scoped `Promise | null` cache, and a `getCytoscape()` function
 * that dynamic-imports cytoscape once. The two cached promises lived
 * side by side, so when both panels mounted at the same time they each
 * triggered their own `import('cytoscape')` call — Vite's module
 * cache deduplicates the *module* but not the *promise object*.
 *
 * Lifting both the type alias and the loader here gives a single
 * promise shared across every cytoscape-using panel, so the dynamic
 * import resolves once and a token rename on the dynamic-import shape
 * (e.g. `m.default ?? m`) only has one site to update.
 */
export type CyCore = cytoscape.Core

let cytoscapeModulePromise: Promise<typeof cytoscape> | null = null

export function getCytoscape(): Promise<typeof cytoscape> {
  if (!cytoscapeModulePromise) {
    cytoscapeModulePromise = import('cytoscape').then(m => m.default ?? m)
  }
  return cytoscapeModulePromise
}
