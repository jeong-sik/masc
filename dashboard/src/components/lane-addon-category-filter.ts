import { html } from 'htm/preact'
import { addonCategoryGroups, categoryLabel, type AddonCategoryFilter, type AddonCategoryGroup } from '../lib/lane-addon-category'

export function LaneAddonCategoryFilter({ value, onChange, groups = addonCategoryGroups, label = '역할 필터' }: {
  value: AddonCategoryFilter; onChange: (filter: AddonCategoryFilter) => void;
  groups?: readonly AddonCategoryGroup[]; label?: string;
}) {
  return html`<label>${label} <select class="rounded border bg-transparent px-3 py-2" value=${value}
    onChange=${(event: Event) => {
      const raw = (event.currentTarget as HTMLSelectElement).value
      const selected = (['all', ...groups] as const).find(option => option === raw)
      if (selected !== undefined) onChange(selected)
    }}>
    <option value="all">전체 역할</option>
    ${groups.map(group => html`<option key=${group} value=${group}>${categoryLabel(group)}</option>`)}
  </select></label>`
}
