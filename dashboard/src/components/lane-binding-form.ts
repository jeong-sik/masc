import { html } from 'htm/preact'
import { TextInput, TextArea } from './common/input'
import { ActionButton } from './common/button'
import type { LaneAddonSnapshot } from '../api/lane-addons'
import { bindingErrors, bindingAlternativeLabel, branchSchema, initialBindingInput, inputFromValue, unset,
  type BindingSchema, type BindingInput, type Json } from '../lib/lane-binding-form'

type Props = { schema: BindingSchema; input: BindingInput; name: string; path: string[];
  required: boolean; onChange: (input: BindingInput) => void; runId: string; snapshot: LaneAddonSnapshot }
const selectClass = 'block w-full rounded border border-[var(--border)] bg-[var(--bg)] p-2'
function activate(schema: BindingSchema): BindingInput {
  if (schema.choices) return { kind: 'choice', index: schema.constant ? 0 : -1 }
  if (schema.oneOf || schema.type === 'object' || schema.type === 'array') return initialBindingInput(schema)
  return schema.type === 'boolean' ? { kind: 'boolean', value: false } : { kind: 'text', text: '' }
}
function SourceOutputChooser({ schema, input, onChange, runId, snapshot, name, path }: Props) {
  // This is the typed binding.sources protocol, not a package-name guess.
  if (path.length !== 2 || path[0] !== 'sources' || schema.type !== 'object' || input.kind !== 'object') return null
  const properties = schema.properties
  if (!properties || !['source_id', 'kind', 'installation_id', 'selection'].every(key => properties.has(key))) return null
  const allows = (key: string, value: Json) => { const field = properties.get(key); return field !== undefined && bindingErrors(field, value).length === 0 }
  if (!allows('kind', 'lane_output') || !allows('selection', 'latest_completed')) return null
  const configuration = snapshot.configuration
  if (configuration === null || !configuration.complete) return html`<p>Refresh complete declarations to choose an existing output.</p>`
  const outputs = snapshot.instances.flatMap(instance => {
    const owner = instance.configuration
    if (owner === null || instance.run_id !== runId || !allows('installation_id', owner.id)
      || !configuration.declarations.some(declaration => declaration.instance_id === instance.instance_id
        && declaration.id === owner.id && declaration.applied_revision === owner.revision)) return []
    return [...(schema.required.has('output_id') ? [] : [{ installation: owner.id, output: null as string | null,
      label: `${instance.title} · ${owner.id} · whole output · ${instance.phase.kind}` }]),
      ...Object.keys(instance.package.outputs).filter(output => allows('output_id', output)).map(output => ({ installation: owner.id, output,
        label: `${instance.title} · ${owner.id} / ${output} · ${instance.phase.kind}` }))]
  })
  const use = (index: number) => {
    const selected = outputs[index]
    if (!selected) return
    const values: Record<string, Json> = { kind: 'lane_output', installation_id: selected.installation, selection: 'latest_completed',
      ...(selected.output === null ? {} : { output_id: selected.output }) }
    const next = inputFromValue(schema, values)
    if (next.kind === 'object') next.fields.set('source_id', input.fields.get('source_id') ?? unset)
    onChange(next)
  }
  return html`<label class="block text-sm">Use a current output for ${name}
    <select aria-label=${`Use a current output for ${name}`} class=${selectClass} value="" onChange=${(event: Event) => { const value = (event.target as HTMLSelectElement).value; if (value !== '') use(Number(value)) }}>
      <option value="">${runId ? outputs.length ? 'Choose an observed producer / output' : 'No applied producer in this run; enter fields below' : 'Enter Run ID to list its producers'}</option>
      ${outputs.map((output, i) => html`<option value=${i}>${output.label}</option>`)}
    </select>
    <span class="text-xs">Uses the latest completed output. Current state is an observation, not a guarantee that the next read succeeds.</span>
  </label>`
}
export function LaneBindingField(props: Props) {
  const { schema, input, name, path, required, onChange } = props
  const label = schema.title ? `${name} · ${schema.title}` : name
  const field = () => {
    if (schema.choices) return html`<label class="block">${label}${required ? ' *' : ''}
      <select aria-label=${label + (required ? ' *' : '')} class=${selectClass} value=${input.kind === 'choice' && input.index >= 0 ? String(input.index) : ''}
        onChange=${(event: Event) => { const value = (event.target as HTMLSelectElement).value; onChange(value === '' ? unset : { kind: 'choice', index: Number(value) }) }}>
        <option value="">Choose a value</option>${schema.choices.map((choice, index) => html`<option value=${index}>${typeof choice === 'string' ? choice : JSON.stringify(choice)}</option>`)}
      </select></label>`
    if (schema.oneOf) {
      const current = input.kind === 'union' ? input : initialBindingInput(schema)
      if (current.kind !== 'union') return null
      return html`<div class="space-y-3"><label class="block">${label} alternative *
        <select aria-label=${`${label} alternative *`} class=${selectClass} value=${current.selected === null ? '' : String(current.selected)}
          onChange=${(event: Event) => { const value = (event.target as HTMLSelectElement).value; onChange({ ...current, selected: value === '' ? null : Number(value) }) }}>
          <option value="">Choose an input shape</option>${schema.oneOf.map((branch, index) => html`<option value=${index}>${bindingAlternativeLabel(branch, index)}</option>`)}
        </select></label>
        ${current.selected !== null && html`<${LaneBindingField} ...${props} schema=${branchSchema(schema, current.selected)} input=${current.branches[current.selected]!}
          onChange=${(next: BindingInput) => onChange({ ...current, branches: current.branches.map((item, i) => i === current.selected ? next : item) })} />`}
      </div>`
    }
    if (schema.type === 'object') {
      const current = input.kind === 'object' ? input : initialBindingInput(schema)
      if (current.kind !== 'object') return null
      return html`<fieldset class="min-w-0 space-y-3 rounded border border-[var(--border)] p-3"><legend class="font-semibold">${label}${required ? ' *' : ''}</legend>
        <${SourceOutputChooser} ...${props} input=${current} />
        ${[...schema.properties ?? []].map(([key, child]) => html`<${LaneBindingField} key=${key} ...${props} schema=${child} name=${`${name}.${key}`} path=${[...path, key]}
          required=${schema.required.has(key)} input=${current.fields.get(key) ?? unset}
          onChange=${(next: BindingInput) => onChange({ ...current, fields: new Map(current.fields).set(key, next) })} />`)}
      </fieldset>`
    }
    if (schema.type === 'array') {
      const current = input.kind === 'array' ? input : { kind: 'array' as const, items: [] }
      return html`<fieldset class="min-w-0 space-y-3 rounded border border-[var(--border)] p-3"><legend class="font-semibold">${label}${required ? ' *' : ''}</legend>
        ${current.items.length === 0 && html`<p>No items yet.</p>`}
        ${current.items.map((item, index) => html`<div key=${index} class="space-y-2 border-l-2 border-[var(--border)] pl-3">
          <${LaneBindingField} ...${props} schema=${schema.items!} input=${item} required=${true} name=${`${name}[${index + 1}]`} path=${[...path, String(index)]}
            onChange=${(next: BindingInput) => onChange({ ...current, items: current.items.map((entry, i) => i === index ? next : entry) })} />
          <${ActionButton} onClick=${() => onChange({ ...current, items: current.items.filter((_, i) => i !== index) })}>Remove ${name}[${index + 1}]</${ActionButton}>
        </div>`)}
        <${ActionButton} onClick=${() => onChange({ ...current, items: [...current.items, initialBindingInput(schema.items!)] })}>Add ${name} item</${ActionButton}>
      </fieldset>`
    }
    if (schema.type === 'boolean') return html`<label class="block">${label}${required ? ' *' : ''}
      <select aria-label=${label + (required ? ' *' : '')} class=${selectClass} value=${input.kind === 'boolean' ? String(input.value) : ''}
        onChange=${(event: Event) => { const value = (event.target as HTMLSelectElement).value; onChange(value === '' ? unset : { kind: 'boolean', value: value === 'true' }) }}>
        <option value="">Not set</option><option value="true">true</option><option value="false">false</option>
      </select></label>`
    return html`<label class="block">${label}${required ? ' *' : ''}
      ${schema.type === 'string'
        ? html`<${TextArea} class="block w-full" rows=${2} value=${input.kind === 'text' ? input.text : ''}
            onInput=${(event: Event) => onChange({ kind: 'text', text: (event.target as HTMLTextAreaElement).value })} />`
        : html`<${TextInput} class="block w-full" value=${input.kind === 'text' ? input.text : ''}
            onInput=${(event: Event) => onChange({ kind: 'text', text: (event.target as HTMLInputElement).value })} />`}
    </label>`
  }
  return html`<div class="min-w-0 space-y-1">
    ${!required && html`<label class="flex items-center gap-2 text-sm"><input type="checkbox" checked=${input.kind !== 'unset'}
      onChange=${(event: Event) => onChange((event.target as HTMLInputElement).checked ? activate(schema) : unset)} />Include ${name}</label>`}
    ${(required || input.kind !== 'unset') && field()}
    ${schema.description && html`<p class="text-sm text-[var(--color-fg-muted)] whitespace-pre-wrap">${schema.description}</p>`}
  </div>`
}
