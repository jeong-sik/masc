import type cytoscape from 'cytoscape'

/**
 * Cytoscape singleton lazy-loader.
 *
 * `common/cytoscape-fsm.ts` uses this loader so cytoscape's dynamic
 * import shape is handled in one place.
 */
export type CyCore = cytoscape.Core

let cytoscapeModulePromise: Promise<typeof cytoscape> | null = null

export function getCytoscape(): Promise<typeof cytoscape> {
  if (!cytoscapeModulePromise) {
    cytoscapeModulePromise = import('cytoscape').then(m => m.default ?? m)
  }
  return cytoscapeModulePromise
}
