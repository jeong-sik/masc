import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import { useSignal } from '@preact/signals'
import {
  createSkill, fetchSkillAuthoringTools, fetchWritableSkillSources, previewNewSkillSource,
  type SkillAuthoringTool, type SkillCreateInput, type SkillCreateReceipt,
  type SkillEditorPreview, type SkillIdentity, type WritableSkillSource,
} from '../api/dashboard-skills'
import { SkillFlowView } from './skill-flow-view'

interface DraftNode {
  key: number
  id: string
  tool: string
  mode: 'args' | 'template'
  input: string
  after: readonly number[]
}
interface DraftExport { key: number; name: string; node: number | null; pointer: string }
type SkillKind = 'instruction' | 'composition'

export function createReceiptMessage(receipt: SkillCreateReceipt): string {
  switch (receipt.status) {
    case 'created_and_published': return 'created and published'
    case 'created_but_shadowed': return `created and published, but shadowed by ${receipt.winner.source_id}/${receipt.winner.package_id}: Keepers see that one by name`
    case 'created_but_unpublished': return `created but NOT published: ${receipt.reason}`
  }
}

function skillSource(draft: {
  kind: SkillKind; name: string; description: string; instructions: string
  execution: 'inline' | 'async'; policy: 'fail_fast' | 'continue_independent'
  nodes: readonly DraftNode[]; exports: readonly DraftExport[]
}): string {
  const quote = JSON.stringify
  const header = `---\nname: ${quote(draft.name)}\ndescription: ${quote(draft.description)}\n---\n\n`
  const body = `# ${draft.name}\n\n${draft.instructions}\n`
  if (draft.kind === 'instruction') return header + body
  const nodeId = (key: number | null) => {
    const node = draft.nodes.find(candidate => candidate.key === key)
    if (!node) throw new Error('Select an existing step for every output and dependency.')
    return node.id
  }
  const nodes = draft.nodes.map(node => {
    let input: unknown
    try { input = JSON.parse(node.input) }
    catch { throw new Error(`Step ${node.id || '(unnamed)'}: input must be valid JSON.`) }
    return { id: node.id, tool: node.tool, after: node.after.map(nodeId),
      ...(node.mode === 'args' ? { args: input } : { input }) }
  })
  const plan = { nodes, branch_failure_policy: draft.policy,
    exports: draft.exports.map(output => ({ name: output.name, node: nodeId(output.node), pointer: output.pointer })) }
  // This is the existing public plan_json grammar. The server's parser owns
  // schema checks, dependency ordering, cycles, output pointers and admission.
  return `${header}\`\`\`toml composition\n[[compositions]]\nname = ${quote(draft.name)}\ndescription = ${quote(draft.description)}\nexecution = ${quote(draft.execution)}\nplan_json = ${quote(JSON.stringify(plan))}\n\`\`\`\n\n${body}`
}

function sameInput(left: SkillCreateInput, right: SkillCreateInput): boolean {
  return left.source_id === right.source_id && left.package_id === right.package_id
    && left.kind === right.kind && left.source_text === right.source_text
}

export function SkillCreateForm({ isCurrent, onReceipt, onRequestError, onPublished }: {
  isCurrent: () => boolean
  onReceipt: (identity: SkillIdentity, receipt: SkillCreateReceipt) => void
  onRequestError: (identity: SkillIdentity, detail: string) => void
  onPublished: () => Promise<void>
}) {
  const kind = useSignal<SkillKind>('instruction')
  const name = useSignal('')
  const description = useSignal('')
  const instructions = useSignal('')
  const source = useSignal('')
  const sources = useSignal<readonly WritableSkillSource[]>([])
  const sourceError = useSignal<string | null>(null)
  const sourcesLoading = useSignal(true)
  const execution = useSignal<'inline' | 'async'>('inline')
  const policy = useSignal<'fail_fast' | 'continue_independent'>('fail_fast')
  const nodes = useSignal<readonly DraftNode[]>([])
  const outputs = useSignal<readonly DraftExport[]>([])
  const nextKey = useRef(1)
  const tools = useSignal<readonly SkillAuthoringTool[]>([])
  const toolsLoaded = useSignal(false)
  const toolsLoading = useSignal(false)
  const toolsError = useSignal<string | null>(null)
  const previewBusy = useSignal(false)
  const pendingCreates = useSignal<readonly SkillCreateInput[]>([])
  const statusRequest = useRef(0)
  const status = useSignal<string | null>(null)
  const preview = useSignal<{ input: SkillCreateInput; value: SkillEditorPreview } | null>(null)
  const active = useRef(true)
  const current = () => active.current && isCurrent()
  const input = (): SkillCreateInput => ({ kind: kind.value, source_id: source.value, package_id: name.value,
    source_text: skillSource({ kind: kind.value, name: name.value, description: description.value,
      instructions: instructions.value, execution: execution.value, policy: policy.value,
      nodes: nodes.value, exports: outputs.value }) })

  const loadSources = async () => {
    if (!current()) return
    sourcesLoading.value = true
    sourceError.value = null
    try {
      const result = await fetchWritableSkillSources()
      if (!current()) return
      sources.value = result
      // With several locations, the author chooses the intended authority.
      if (result.length === 1 && !source.value) source.value = result[0]!.source_id
    } catch (cause) {
      if (current()) sourceError.value = cause instanceof Error ? cause.message : String(cause)
    } finally { if (current()) sourcesLoading.value = false }
  }
  const loadTools = async () => {
    if (!current() || toolsLoading.value) return
    toolsLoading.value = true
    toolsError.value = null
    try {
      const result = await fetchSkillAuthoringTools()
      if (!current()) return
      tools.value = result
      toolsLoaded.value = true
    } catch (cause) {
      if (current()) toolsError.value = cause instanceof Error ? cause.message : String(cause)
    } finally { if (current()) toolsLoading.value = false }
  }
  useEffect(() => {
    void loadSources()
    return () => { active.current = false }
  }, [])
  useEffect(() => {
    if (kind.value === 'composition' && !toolsLoaded.value) void loadTools()
  }, [kind.value])

  const updateNode = (key: number, patch: Partial<DraftNode>) => {
    nodes.value = nodes.value.map(node => node.key === key ? { ...node, ...patch } : node)
  }
  const updateOutput = (key: number, patch: Partial<DraftExport>) => {
    outputs.value = outputs.value.map(output => output.key === key ? { ...output, ...patch } : output)
  }
  const removeNode = (key: number) => {
    nodes.value = nodes.value.filter(node => node.key !== key)
      .map(node => ({ ...node, after: node.after.filter(dependency => dependency !== key) }))
    outputs.value = outputs.value.map(output => output.node === key ? { ...output, node: null } : output)
  }
  let generated: SkillCreateInput | null = null
  let generationError: string | null = null
  try { generated = input() }
  catch (cause) { generationError = cause instanceof Error ? cause.message : String(cause) }
  const visiblePreview = generated && preview.value && sameInput(generated, preview.value.input)
    ? preview.value.value : null
  const creatingCurrent = generated !== null && pendingCreates.value.some(pending => sameInput(pending, generated))

  const validate = async () => {
    if (!current() || previewBusy.value) return
    previewBusy.value = true
    const generation = ++statusRequest.current
    status.value = null
    try {
      const requested = input()
      const result = await previewNewSkillSource(requested)
      if (!current()) return
      const identity = result.profile.reference.identity
      if (identity.source_id !== requested.source_id || identity.package_id !== requested.package_id
        || identity.name !== requested.package_id) throw new Error('Preview returned a different Skill identity.')
      preview.value = { input: requested, value: result }
      if (generation === statusRequest.current) status.value = sameInput(input(), requested) ? null : 'Draft changed during validation. Validate the current draft to refresh the preview.'
    } catch (cause) {
      if (current()) {
        preview.value = null
        if (generation === statusRequest.current) status.value = cause instanceof Error ? cause.message : String(cause)
      }
    } finally { if (current()) previewBusy.value = false }
  }
  const publish = async (event: SubmitEvent) => {
    event.preventDefault()
    if (!current()) return
    let requested: SkillCreateInput
    try { requested = input() }
    catch (cause) { status.value = cause instanceof Error ? cause.message : String(cause); return }
    if (pendingCreates.value.some(pending => sameInput(pending, requested))) return
    const generation = ++statusRequest.current
    const identity = { source_id: requested.source_id, package_id: requested.package_id, name: requested.package_id }
    pendingCreates.value = [...pendingCreates.value, requested]
    status.value = 'Validating and publishing…'
    let received = false
    try {
      const receipt = await createSkill(requested)
      received = true
      // Mutation receipts survive an access/workspace change in the parent.
      onReceipt(identity, receipt)
      if (!current()) return
      if (generation === statusRequest.current) status.value = `${identity.source_id}/${identity.package_id}: ${createReceiptMessage(receipt)}`
      await onPublished()
    } catch (cause) {
      const detail = cause instanceof Error ? cause.message : String(cause)
      if (!received) onRequestError(identity, detail)
      if (current() && generation === statusRequest.current) status.value = detail
    } finally { if (current()) pendingCreates.value = pendingCreates.value.filter(pending => pending !== requested) }
  }

  return html`<form class="mb-4 grid gap-3 rounded border border-[var(--color-border)] p-3" data-testid="skill-create" onSubmit=${publish}>
    <div class="grid gap-2 md:grid-cols-3">
      <label>Save location<select aria-label="Skill source" class="ss-input w-full" value=${source.value} required onChange=${(event: Event) => { source.value = (event.currentTarget as HTMLSelectElement).value }}>
        <option value="">${sourcesLoading.value ? 'Loading sources…' : 'Choose a writable source'}</option>
        ${sources.value.map(item => html`<option key=${item.source_id} value=${item.source_id}>${item.source_id}</option>`)}
      </select></label>
      <label>Kind<select aria-label="Skill kind" class="ss-input w-full" value=${kind.value} onChange=${(event: Event) => { kind.value = (event.currentTarget as HTMLSelectElement).value as SkillKind }}>
        <option value="instruction">Instruction · on demand</option><option value="composition">Composition · tool flow</option>
      </select></label>
      <label>Package and name<input aria-label="Skill name" class="ss-input mono w-full" value=${name.value} placeholder="skill-name" required onInput=${(event: Event) => { name.value = (event.currentTarget as HTMLInputElement).value }} /></label>
    </div>
    ${sourceError.value ? html`<div role="alert">Sources unavailable: ${sourceError.value} <button type="button" class="ss-btn" onClick=${loadSources}>Reload sources</button></div>` : null}
    ${!sourcesLoading.value && !sourceError.value && sources.value.length === 0 ? html`<div role="status">No writable Skill source is ready. Configure one before creating a package.</div>` : null}
    <label>When to use<input aria-label="Skill description" class="ss-input w-full" value=${description.value} placeholder="When should an agent use this?" required onInput=${(event: Event) => { description.value = (event.currentTarget as HTMLInputElement).value }} /></label>
    <label>Instructions<textarea aria-label="Skill instructions" class="ss-input min-h-24 w-full" value=${instructions.value} placeholder="Describe the procedure, expected result and how to verify it." required=${kind.value === 'instruction'} onInput=${(event: Event) => { instructions.value = (event.currentTarget as HTMLTextAreaElement).value }} /></label>
    <p class="ss-muted">Agents discover the name and description first; instructions are loaded on demand. Reference package resources by relative path. Creating this document does not upload resource files.</p>
    ${kind.value === 'composition' ? html`<section aria-label="Composition builder" class="grid gap-3">
      <div class="grid gap-2 md:grid-cols-2">
        <label>Execution<select aria-label="Composition execution" class="ss-input w-full" value=${execution.value} onChange=${(event: Event) => { execution.value = (event.currentTarget as HTMLSelectElement).value as 'inline' | 'async' }}>
          <option value="inline">Inline · return in the tool call</option><option value="async">Async · durable owned work</option>
        </select></label>
        <label>On branch failure<select aria-label="Branch failure policy" class="ss-input w-full" value=${policy.value} onChange=${(event: Event) => { policy.value = (event.currentTarget as HTMLSelectElement).value as 'fail_fast' | 'continue_independent' }}>
          <option value="fail_fast">Stop the plan</option><option value="continue_independent">Continue independent branches</option>
        </select></label>
      </div>
      <p class="ss-muted">Independent steps may share a batch when their tool contracts permit concurrency. Async admission and input/output schemas are checked by the same compiler used at publication.</p>
      ${toolsError.value ? html`<div role="alert">Tool contracts unavailable: ${toolsError.value} <button class="ss-btn" type="button" onClick=${loadTools}>Reload tool contracts</button></div>` : null}
      ${toolsLoading.value ? html`<div role="status">Loading current tool contracts…</div>` : null}
      <datalist id="skill-authoring-tools">${tools.value.map(tool => html`<option key=${tool.name} value=${tool.name}>${tool.description}</option>`)}</datalist>
      ${nodes.value.map((node, index) => {
        const tool = tools.value.find(candidate => candidate.name === node.tool)
        return html`<fieldset key=${node.key} class="grid gap-2 rounded border border-[var(--color-border)] p-2">
          <legend>Step ${index + 1}</legend>
          <div class="flex flex-wrap gap-2"><input aria-label=${`Step ${index + 1} ID`} class="ss-input mono" value=${node.id} required onInput=${(event: Event) => updateNode(node.key, { id: (event.currentTarget as HTMLInputElement).value })} />
            <input aria-label=${`Step ${index + 1} tool`} class="ss-input mono flex-1" list="skill-authoring-tools" placeholder="Choose a tool" value=${node.tool} required onInput=${(event: Event) => updateNode(node.key, { tool: (event.currentTarget as HTMLInputElement).value })} />
            <button class="ss-btn" type="button" aria-label=${`Remove step ${index + 1}`} onClick=${() => removeNode(node.key)}>Remove</button>
          </div>
          ${tool ? html`<div class="ss-muted">${tool.description} · ${tool.execution}<details><summary>Input / output contracts</summary>
            <pre class="overflow-auto whitespace-pre-wrap">Input: ${JSON.stringify(tool.input_schema, null, 2)}</pre>
            ${tool.output.kind === 'json' ? html`<pre class="overflow-auto whitespace-pre-wrap">Composable output: ${JSON.stringify(tool.output.schema, null, 2)}</pre>` : html`<div>Output is opaque; other steps cannot reference it.</div>`}
          </details></div>` : null}
          <label>Input mode<select aria-label=${`Step ${index + 1} input mode`} class="ss-input" value=${node.mode} onChange=${(event: Event) => updateNode(node.key, { mode: (event.currentTarget as HTMLSelectElement).value as 'args' | 'template' })}>
            <option value="args">Fixed JSON arguments</option><option value="template">Typed input template</option>
          </select></label>
          <textarea aria-label=${`Step ${index + 1} input`} class="ss-input mono min-h-20 w-full" value=${node.input} onInput=${(event: Event) => updateNode(node.key, { input: (event.currentTarget as HTMLTextAreaElement).value })} />
          ${node.mode === 'template' ? html`<div class="ss-muted">Use literal, output, object or array templates. Example: {"kind":"output","node":"step-1","pointer":"/value"}. Output references also establish dependencies; keep referenced IDs current.</div>` : null}
          <div>Wait for ${nodes.value.length === 1 ? html`<span class="ss-muted">no other steps</span>` : nodes.value.filter(other => other.key !== node.key).map(other => html`<label key=${other.key} class="ml-2"><input type="checkbox" checked=${node.after.includes(other.key)} onChange=${(event: Event) => updateNode(node.key, { after: (event.currentTarget as HTMLInputElement).checked ? [...node.after, other.key] : node.after.filter(key => key !== other.key) })} /> ${other.id || '(unnamed)'}</label>`)}</div>
        </fieldset>`
      })}
      <button class="ss-btn justify-self-start" type="button" onClick=${() => { const key = nextKey.current++; nodes.value = [...nodes.value, { key, id: `step-${key}`, tool: '', mode: 'args', input: '{}', after: [] }] }}>Add step</button>
      <fieldset class="grid gap-2"><legend>Named outputs</legend>
        <p class="ss-muted">Choose which declared tool output fields the composition returns. Empty pointer selects the whole output. With no named outputs, the executor retains its normal node results.</p>
        ${outputs.value.map((output, index) => html`<div key=${output.key} class="flex flex-wrap gap-2">
          <input aria-label=${`Output ${index + 1} name`} class="ss-input" placeholder="result" required value=${output.name} onInput=${(event: Event) => updateOutput(output.key, { name: (event.currentTarget as HTMLInputElement).value })} />
          <select aria-label=${`Output ${index + 1} step`} class="ss-input" required value=${output.node === null ? '' : String(output.node)} onChange=${(event: Event) => updateOutput(output.key, { node: (event.currentTarget as HTMLSelectElement).value === '' ? null : Number((event.currentTarget as HTMLSelectElement).value) })}>
            <option value="">Choose a step</option>${nodes.value.map(node => html`<option key=${node.key} value=${String(node.key)}>${node.id || '(unnamed)'}</option>`)}
          </select>
          <input aria-label=${`Output ${index + 1} pointer`} class="ss-input mono flex-1" placeholder="/path/to/field (empty = whole output)" value=${output.pointer} onInput=${(event: Event) => updateOutput(output.key, { pointer: (event.currentTarget as HTMLInputElement).value })} />
          <button class="ss-btn" type="button" aria-label=${`Remove output ${index + 1}`} onClick=${() => { outputs.value = outputs.value.filter(item => item.key !== output.key) }}>Remove</button>
        </div>`)}
        <button class="ss-btn justify-self-start" type="button" onClick=${() => { outputs.value = [...outputs.value, { key: nextKey.current++, name: '', node: null, pointer: '' }] }}>Add output</button>
      </fieldset>
    </section>` : null}
    <details><summary>SKILL.md source</summary>${generated ? html`<pre aria-label="New Skill source" class="overflow-auto whitespace-pre-wrap mono">${generated.source_text}</pre>` : html`<div>${generationError}</div>`}</details>
    <div class="flex flex-wrap items-center gap-2">
      <button class="ss-btn" type="button" disabled=${!source.value || previewBusy.value} onClick=${validate}>${previewBusy.value ? 'Validating…' : 'Validate draft'}</button>
      <button class="ss-btn" type="submit" disabled=${!source.value || creatingCurrent}>${creatingCurrent ? 'Publishing…' : 'Create + publish'}</button>
      <span class="ss-muted">Validation writes no files. Create validates again and reports the publication outcome.</span>
    </div>
    ${pendingCreates.value.length > 0 ? html`<div role="status">${pendingCreates.value.length} create request(s) awaiting a response. Each receipt retains its submitted identity.</div>` : null}
    ${visiblePreview ? html`<section aria-label="New Skill preview" class="rounded border border-[var(--color-border)] p-2">
      <div>${visiblePreview.profile.kind} · ${visiblePreview.profile.execution} · ${visiblePreview.profile.plan.node_count} nodes · draft revision ${visiblePreview.profile.reference.content_revision}</div>
      <${SkillFlowView} profile=${visiblePreview.profile} />
      ${visiblePreview.diagnostics.map(detail => html`<div class="text-[var(--color-status-warn)]">${detail}</div>`)}
      <div class="ss-muted">Draft validated; no files written. Source availability, name conflicts and publication are checked when creating.</div>
    </section>` : preview.value ? html`<div role="status">Draft changed; the previous preview no longer describes these bytes.</div>` : null}
    ${status.value ? html`<div role="status" data-testid="skill-create-status">${status.value}</div>` : null}
  </form>`
}
