// keeper-v2 design waterfall foot molecule — the Waterfall component's
// footer from prototypes/keeper-v2/molecules.jsx: measured total + the full
// four-kind legend (ctx / reason / tool / gen).
//
// The live turn waterfall (keeper-turn-inspector.ts TimelineTab) renders rows
// with kind: 'ctx' | 'reason' | 'tool' | 'gen' (a ctx phase is built at
// keeper-turn-inspector.ts:600) but its legend omits ctx. This molecule
// carries the complete design legend; integration can swap it in for the
// existing .ti-wf-foot block.

import { html } from 'htm/preact'
import type { VNode } from 'preact'

export function MoleculeWaterfallFoot({ total }: { total: string }): VNode {
  return html`
    <div class="ti-wf-foot">
      <span>total <b>${total}</b></span>
      <div class="ti-wf-legend">
        <span><i class="ti-k-ctx"></i>ctx</span>
        <span><i class="ti-k-reason"></i>reason</span>
        <span><i class="ti-k-tool"></i>tool</span>
        <span><i class="ti-k-gen"></i>gen</span>
      </div>
    </div>
  `
}
