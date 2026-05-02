import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { ActionButton } from '../common/button'
import { Checkbox } from '../common/checkbox'
import { TextArea, TextInput } from '../common/input'
import { showToast } from '../common/toast'
import {
  generatePersonaDraft,
  personaAuthoringResult,
  personaDraft,
  personaGenerating,
  personaSaveResult,
  personaSaving,
  savePersonaDraft,
  spawnKeeperFromPersona,
  spawning,
} from './keeper-spawn-state'

const concept = signal('')
const handle = signal('')
const displayName = signal('')
const proactiveEnabled = signal(false)
const overwrite = signal(false)
const profileText = signal('')

function syncProfileText() {
  const draft = personaDraft.value
  profileText.value = draft ? JSON.stringify(draft.profile, null, 2) : ''
}

function applyProfileText(): boolean {
  const draft = personaDraft.value
  if (!draft) return false
  try {
    const parsed = JSON.parse(profileText.value)
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      throw new Error('profile JSON must be an object')
    }
    personaDraft.value = { ...draft, profile: parsed as Record<string, unknown> }
    return true
  } catch (err) {
    showToast(err instanceof Error ? err.message : 'profile JSON parse failed', 'error')
    return false
  }
}

async function generateDraft() {
  await generatePersonaDraft({
    concept: concept.value,
    handle: handle.value,
    displayName: displayName.value,
    proactiveEnabled: proactiveEnabled.value,
  })
  syncProfileText()
}

async function saveDraft(dryRun: boolean) {
  if (!applyProfileText()) return
  await savePersonaDraft({ overwrite: overwrite.value, dryRun })
}

function prettyValue(value: unknown): string {
  if (value === undefined || value === null) return ''
  if (typeof value === 'string') return value
  return JSON.stringify(value)
}

export function PersonaGenerator() {
  const draft = personaDraft.value
  const saveResult = personaSaveResult.value
  const savedForDraft = Boolean(draft && saveResult?.handle === draft.handle && saveResult.saved)

  return html`
    <div class="grid gap-4 lg:grid-cols-[minmax(260px,0.9fr)_minmax(360px,1.2fr)]">
      <div class="space-y-3">
        <div class="grid gap-2">
          <label class="text-3xs text-[var(--color-fg-muted)]" for="persona-concept">컨셉</label>
          <${TextArea}
            id="persona-concept"
            rows=${5}
            value=${concept.value}
            placeholder="good evil chaos research keeper"
            ariaLabel="persona concept"
            onInput=${(e: Event) => { concept.value = (e.target as HTMLTextAreaElement).value }}
            class="!px-2 !py-2 !text-2xs"
          />
        </div>

        <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
          <label class="grid gap-1 text-3xs text-[var(--color-fg-muted)]">
            handle
            <${TextInput}
              type="text"
              value=${handle.value}
              placeholder="auto"
              ariaLabel="persona handle"
              onInput=${(e: Event) => { handle.value = (e.target as HTMLInputElement).value }}
              class="!px-2 !py-1.5 !text-2xs"
            />
          </label>
          <label class="grid gap-1 text-3xs text-[var(--color-fg-muted)]">
            display
            <${TextInput}
              type="text"
              value=${displayName.value}
              placeholder="auto"
              ariaLabel="persona display name"
              onInput=${(e: Event) => { displayName.value = (e.target as HTMLInputElement).value }}
              class="!px-2 !py-1.5 !text-2xs"
            />
          </label>
          <label class="flex items-center gap-2 pt-5 text-2xs text-[var(--color-fg-primary)]">
            <${Checkbox}
              checked=${proactiveEnabled.value}
              ariaLabel="proactive"
              onChange=${(checked: boolean) => { proactiveEnabled.value = checked }}
            />
            proactive
          </label>
        </div>

        <div class="flex flex-wrap gap-2">
          <${ActionButton}
            variant="primary"
            size="sm"
            disabled=${personaGenerating.value}
            ariaBusy=${personaGenerating.value}
            onClick=${() => void generateDraft()}
          >${personaGenerating.value ? '생성 중...' : '초안 생성'}<//>
          <${ActionButton}
            variant="ghost"
            size="sm"
            disabled=${!draft || personaSaving.value}
            onClick=${() => void saveDraft(true)}
          >저장 dry-run<//>
          <${ActionButton}
            variant="primary"
            size="sm"
            disabled=${!draft || personaSaving.value}
            ariaBusy=${personaSaving.value}
            onClick=${() => void saveDraft(false)}
          >${personaSaving.value ? '저장 중...' : '저장'}<//>
          <label class="flex items-center gap-1.5 text-3xs text-[var(--color-fg-muted)]">
            <${Checkbox}
              checked=${overwrite.value}
              ariaLabel="overwrite"
              onChange=${(checked: boolean) => { overwrite.value = checked }}
            />
            overwrite
          </label>
        </div>
      </div>

      <div class="space-y-3">
        <div class="grid gap-2">
          <div class="flex items-center justify-between">
            <label class="text-3xs text-[var(--color-fg-muted)]" for="persona-profile-json">profile.json</label>
            ${draft ? html`<span class="text-3xs text-[var(--color-fg-muted)]">${draft.handle}</span>` : null}
          </div>
          <${TextArea}
            id="persona-profile-json"
            rows=${18}
            value=${profileText.value}
            placeholder="초안을 생성하면 profile.json이 표시됩니다"
            ariaLabel="persona profile.json"
            onInput=${(e: Event) => { profileText.value = (e.target as HTMLTextAreaElement).value }}
            class="!bg-[var(--color-bg-page)] !px-2 !py-2 !text-3xs font-mono leading-5"
          />
        </div>

        ${draft?.fieldExplanations.length ? html`
          <div class="rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--white-4)]">
            ${draft.fieldExplanations.map(item => html`
              <div key=${item.path} class="grid grid-cols-[minmax(120px,0.35fr)_1fr] gap-2 border-b border-[var(--color-border-default)] px-2 py-1.5 text-3xs">
                <span class="font-mono text-[var(--color-accent-fg)]">${item.path}</span>
                <span class="text-[var(--color-fg-primary)]">${item.effect ?? prettyValue(item.value)}</span>
              </div>
            `)}
          </div>
        ` : null}

        <div class="flex flex-wrap gap-2">
          <${ActionButton}
            variant="ghost"
            size="sm"
            disabled=${!savedForDraft || spawning.value}
            onClick=${() => draft && void spawnKeeperFromPersona(draft.handle, { dryRun: true })}
          >키퍼 dry-run<//>
          <${ActionButton}
            variant="primary"
            size="sm"
            disabled=${!savedForDraft || spawning.value}
            onClick=${() => draft && void spawnKeeperFromPersona(draft.handle)}
          >키퍼 시작<//>
          ${saveResult?.profilePath ? html`
            <span class="self-center text-3xs text-[var(--color-fg-muted)]">${saveResult.profilePath}</span>
          ` : null}
        </div>

        ${personaAuthoringResult.value ? html`
          <pre class="max-h-48 overflow-auto rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--white-4)] p-2 text-3xs ${personaAuthoringResult.value.success ? 'text-[var(--color-fg-primary)]' : 'text-[var(--color-status-err)]'}">${personaAuthoringResult.value.message}</pre>
        ` : null}
      </div>
    </div>
  `
}
