/**
 * Selective 42% / 58% `@container` Master-Detail primitive.
 * Automatically collapses to a single stack under `860px` container width via `primitives.css`.
 */

import { html } from 'htm/preact'
import type { ComponentChildren } from 'preact'

export interface MasterDetailProps {
  readonly master: ComponentChildren
  readonly detail: ComponentChildren
  readonly emptyDetail?: ComponentChildren
  readonly hasSelection?: boolean
  readonly masterLabel?: string
  readonly detailLabel?: string
  readonly className?: string
}

export function MasterDetail(props: MasterDetailProps) {
  const showDetail = props.hasSelection ?? true

  return html`
    <div class=${`md-split ${props.className ?? ''}`.trim()}>
      <section class="md-master" aria-label=${props.masterLabel ?? '목록'}>
        ${props.master}
      </section>
      <section class="md-detail" aria-label=${props.detailLabel ?? '상세 정보'}>
        ${showDetail
          ? props.detail
          : (props.emptyDetail ?? html`<div class="dtable-absent">항목을 선택하세요.</div>`)}
      </section>
    </div>
  `
}
