import { createElement, type ComponentType, type VNode } from 'preact'

export interface PreloadableLazy<P extends object> {
  readonly Component: ComponentType<P>
  readonly preload: () => Promise<void>
}

/**
 * Suspense-compatible lazy component with synchronous fast-path once preloaded
 * and transient-error recovery (unlike `preact/compat`'s `lazy()`, a failed
 * background preload or chunk load clears its pending flight so retries succeed).
 */
export function createPreloadableLazy<P extends object>(
  loader: () => Promise<ComponentType<P>>,
): PreloadableLazy<P> {
  let resolved: ComponentType<P> | null = null
  let pending: Promise<void> | null = null
  let wantRenderError = false
  let renderError: unknown = null

  const ensureLoad = (forRender: boolean): Promise<void> => {
    if (resolved !== null) return Promise.resolve()
    if (forRender) wantRenderError = true
    if (pending === null) {
      renderError = null
      const run = loader().then(
        (comp) => {
          resolved = comp
          if (pending === run) {
            pending = null
            wantRenderError = false
          }
        },
        (err: unknown) => {
          if (pending === run) {
            const shouldRecord = wantRenderError
            pending = null
            wantRenderError = false
            if (shouldRecord) renderError = err
          }
          throw err
        },
      )
      pending = run
    }
    return pending
  }

  function PreloadableLazyComponent(props: P): VNode<P> {
    if (resolved !== null) return createElement(resolved, props)
    if (renderError !== null) {
      const err = renderError
      renderError = null
      throw err
    }
    throw ensureLoad(true)
  }
  PreloadableLazyComponent.displayName = 'PreloadableLazy'

  return {
    Component: PreloadableLazyComponent,
    preload: () => ensureLoad(false),
  }
}
