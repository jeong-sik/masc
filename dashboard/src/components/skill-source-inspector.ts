import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { readSkillSource, type SkillEditorLoaded, type SkillReference } from '../api/dashboard-skills'

type SourceState =
  | { kind: 'loading'; identity: string }
  | { kind: 'loaded'; identity: string; value: SkillEditorLoaded }
  | { kind: 'error'; identity: string; detail: string }

function referenceKey(reference: SkillReference): string {
  return JSON.stringify([reference.identity.source_id, reference.identity.package_id,
    reference.identity.name, reference.content_revision])
}

export function SkillSourceInspector({ reference }: { reference: SkillReference }) {
  const identity = referenceKey(reference)
  const [attempt, setAttempt] = useState(0)
  const [state, setState] = useState<SourceState>({ kind: 'loading', identity })
  useEffect(() => {
    let active = true
    setState({ kind: 'loading', identity })
    void readSkillSource(reference).then(
      value => {
        if (!active) return
        setState(referenceKey(value.reference) === identity
          ? { kind: 'loaded', identity, value }
          : { kind: 'error', identity, detail: 'Returned source does not match the selected Skill revision.' })
      },
      cause => { if (active) setState({ kind: 'error', identity, detail: cause instanceof Error ? cause.message : String(cause) }) },
    )
    return () => { active = false }
  }, [identity, attempt])
  const current: SourceState = state.identity === identity ? state : { kind: 'loading', identity }
  return html`
    <section class="min-w-0 rounded border border-[var(--color-border)] p-3" aria-label="Skill instructions">
      <h3 class="font-semibold">Instructions · exact source</h3>
      <p class="ss-muted">Published SKILL.md including frontmatter. Reading this source does not edit or activate the Skill.</p>
      ${current.kind === 'loading' ? html`<p role="status">Loading exact source revision…</p>`
        : current.kind === 'error' ? html`<div role="alert">
          <p>Source unavailable: ${current.detail}</p>
          <button class="ss-btn" type="button" onClick=${() => setAttempt(value => value + 1)}>Retry source read</button>
        </div>`
        : html`<p class="ss-muted mono break-all">Revision ${current.value.reference.content_revision} · ${current.value.access}</p>
          <pre tabindex="0" aria-label="Exact Skill source" class="m-0 max-h-[32rem] overflow-auto whitespace-pre-wrap break-words rounded bg-[var(--color-bg-surface)] p-3 text-sm">${current.value.source_text}</pre>`}
    </section>
  `
}
