// Synchronous-mount variant of KpiStripIsland — RFC 0017 §7d spike.
//
// The shipping `KpiStripIsland` (kpi-strip-island.ts) wires its Solid
// subtree through `useEffect`, which fires at task tier. Headless
// Chromium measurement at n=16 (PR #12280) showed this adds ~30 ms of
// fixed overhead per mount and per update — large enough that island
// throughput is half of the Preact original at production scale.
//
// This variant moves the Solid mount/dispose into a Preact ref callback
// (fires synchronously during the commit phase) and the prop sync into
// `useLayoutEffect` (fires synchronously before paint). Both shift the
// work out of task tier, eliminating the bulk of the ~30 ms gap.
//
// Tradeoff: Preact's ref callback fires synchronously in the same tick
// as the surrounding render. Calling `solidRender` inside it nests one
// renderer inside another; experimentally this works because Solid's
// render is itself synchronous and does not yield. We retain the
// caller's prop reference identity by reading `props` directly inside
// the layout-effect, so each parent re-render pushes the latest data.
//
// Used only by the bench page for now; the production wrapper stays on
// the well-tested useEffect path until this spike's measurement is
// reviewed.

import { useLayoutEffect, useRef } from 'preact/hooks'
import { render as solidRender } from 'solid-js/web'
import type { Setter } from 'solid-js'
import type { VNode } from 'preact'
import { html } from 'htm/preact'
import {
  createKpiStripIsland,
  type KpiStripIslandData,
} from './kpi-strip-island-solid.solid'

export type { KpiStripIslandData } from './kpi-strip-island-solid.solid'

interface MountedIsland {
  dispose: () => void
  setState: Setter<KpiStripIslandData>
}

export function KpiStripIslandSync(props: KpiStripIslandData): VNode {
  const handleRef = useRef<MountedIsland | null>(null)

  // Mount/unmount via ref callback. Preact invokes this synchronously
  // during commit when the host `<div>` is attached (or detached). The
  // Solid render is also synchronous, so by the time the surrounding
  // commit returns, the cells are already in the DOM.
  const mount = (el: HTMLDivElement | null): void => {
    if (el !== null && handleRef.current === null) {
      const island = createKpiStripIsland(props)
      const dispose = solidRender(island.jsx, el)
      handleRef.current = { dispose, setState: island.setState }
      return
    }
    if (el === null && handleRef.current !== null) {
      handleRef.current.dispose()
      handleRef.current = null
    }
  }

  // Push prop changes to the Solid signal in useLayoutEffect — fires
  // synchronously after the DOM commits but before the browser paints.
  // No task-tier hop, so the update reaches Solid in the same frame.
  useLayoutEffect(() => {
    handleRef.current?.setState(props)
  })

  return html`<div ref=${mount} />`
}
