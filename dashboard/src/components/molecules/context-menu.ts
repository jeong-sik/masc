// keeper-v2 design keeper context-menu molecule — ContextMenu from
// prototypes/keeper-v2/molecules.jsx (.kp-menu). Items are real command
// descriptors supplied by the host (label/danger/onClick); the optional header
// shows the keeper's slot monogram + name.

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { Sigil } from '../v2/primitives-v2'

export type KpMenuItem = { label: string; danger?: boolean; onClick?: () => void } | 'sep'

export function MoleculeContextMenu({
  keeper,
  items,
}: {
  keeper?: { slot: number; mono: string; name: string }
  items: KpMenuItem[]
}): VNode {
  return html`
    <div class="kp-menu">
      ${keeper
        ? html`
            <div class="kp-menu-h">
              <${Sigil} slot=${keeper.slot} size=${17} title=${keeper.name} fontScale=${0.46}>${keeper.mono}</${Sigil}>
              ${keeper.name}
            </div>
          `
        : null}
      ${items.map((it, i) =>
        it === 'sep'
          ? html`<div key=${i} class="kp-menu-sep"></div>`
          : html`
              <button
                key=${i}
                type="button"
                class="kp-menu-i ${it.danger ? 'danger' : ''}"
                onClick=${it.onClick}
              >
                ${it.label}
              </button>
            `
      )}
    </div>
  `
}
