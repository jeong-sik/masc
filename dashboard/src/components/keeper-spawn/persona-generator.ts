import { html } from 'htm/preact'
import { useEffect } from 'preact/hooks'
import { signal } from '@preact/signals'
import { ActionButton } from '../common/button'
import { showToast } from '../common/toast'
import {
  generatePersonaDraft,
  loadPersonaSchema,
  personaAuthoringResult,
  personaDraft,
  personaGenerating,
  personaSaveResult,
  personaSaving,
  personaSchema,
  personaSchemaLoading,
  savePersonaDraft,
  spawnKeeperFromPersona,
  spawning,
} from './keeper-spawn-state'

const concept = signal('')
const handle = signal('')
const displayName = signal('')
const toolPreset = signal('research')
const proactiveEnabled = signal(false)
const overwrite = signal(false)
const profileText = signal('')

function syncProfileText() {
  const draft = personaDraft.value
  profileText.value = draft ? JSON.stringify(draft.profile, null, 2) : ''
}

function appendConceptToken(token: string) {
  const current = concept.value.trim()
  concept.value = current ? `${current}, ${token}` : token
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
    toolPreset: toolPreset.value,
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
  useEffect(() => {
    if (!personaSchema.value && !personaSchemaLoading.value) void loadPersonaSchema()
  }, [])
  const schema = personaSchema.value
  const draft = personaDraft.value
  const saveResult = personaSaveResult.value
  const savedForDraft = Boolean(draft && saveResult?.handle === draft.handle && saveResult.saved)
  const presets = schema?.fieldCatalog
    .find(field => field.path === 'keeper.tool_preset')
    ?.choices
  const presetChoices = Array.isArray(presets)
    ? presets.filter((item): item is string => typeof item === 'string')
    : ['minimal', 'social', 'messaging', 'dispatch', 'coding', 'research', 'delivery', 'full']

  return html`
    <div class="grid gap-4 lg:grid-cols-[minmax(260px,0.9fr)_minmax(360px,1.2fr)]" role="region" aria-label="페르소나 생성기">
      <div class="space-y-3">
        <div class="grid gap-2">
          <label class="text-3xs text-[var(--text-muted)]" for="persona-concept">컨셉</label>
          <textarea autoComplete="off"
            id="persona-concept"
            rows=${5}
            value=${concept.value}
            placeholder="good evil chaos research keeper"
            onInput=${(e: Event) => { concept.value = (e.target as HTMLTextAreaElement).value }}
            class="w-full rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-2 text-2xs text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)] focus-visible:ring-2 focus-visible:ring-[var(--accent)]/50"
          />
        </div>

        ${schema?.archetypeAxes.length ? html`
          <div class="flex flex-wrap gap-1.5">
            ${schema.archetypeAxes.flatMap(axis => axis.choices.slice(0, 5).map(choice => html`
              <${ActionButton}
                key=${`${axis.name}:${choice}`}
                variant="ghost"
                size="sm"
                title=${axis.effect}
                onClick=${() => appendConceptToken(choice)}
              >${choice}<//>
            `))}
          </div>
        ` : null}

        <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
          <label class="grid gap-1 text-3xs text-[var(--text-muted)]">
            handle
            <input
              value=${handle.value}
              placeholder="auto"
              onInput=${(e: Event) => { handle.value = (e.target as HTMLInputElement).value }}
              class="rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1.5 text-2xs text-[var(--text-body)] focus:outline-none focus:border-[var(--accent)] focus-visible:ring-2 focus-visible:ring-[var(--accent)]/50"
            />
          </label>
          <label class="grid gap-1 text-3xs text-[var(--text-muted)]">
            display
            <input
              value=${displayName.value}
              placeholder="auto"
              onInput=${(e: Event) => { displayName.value = (e.target as HTMLInputElement).value }}
              class="rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1.5 text-2xs text-[var(--text-body)] focus:outline-none focus:border-[var(--accent)] focus-visible:ring-2 focus-visible:ring-[var(--accent)]/50"
            />
          </label>
          <label class="grid gap-1 text-3xs text-[var(--text-muted)]">
            preset
            <select autoComplete="off"
              aria-label="도구 프리셋"
              value=${toolPreset.value}
              onChange=${(e: Event) => { toolPreset.value = (e.target as HTMLSelectElement).value }}
              class="rounded border border-[var(--white-10)] bg-[var(--white-4)] px-2 py-1.5 text-2xs text-[var(--text-body)] focus:outline-none focus:border-[var(--accent)] focus-visible:ring-2 focus-visible:ring-[var(--accent)]/50"
            >
              ${presetChoices.map(choice => html`<option key=${choice} value=${choice}>${choice}</option>`)}
            </select>
          </label>
          <label class="flex items-center gap-2 pt-5 text-2xs text-[var(--text-body)]">
            <input
              type="checkbox"
              checked=${proactiveEnabled.value}
              onChange=${(e: Event) => { proactiveEnabled.value = (e.target as HTMLInputElement).checked }}
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
          <label class="flex items-center gap-1.5 text-3xs text-[var(--text-muted)]">
            <input
              type="checkbox"
              checked=${overwrite.value}
              onChange=${(e: Event) => { overwrite.value = (e.target as HTMLInputElement).checked }}
            />
            overwrite
          </label>
        </div>

        ${schema ? html`
          <div class="rounded border border-[var(--white-10)] bg-[var(--white-4)]">
            <div class="border-b border-[var(--white-10)] px-2 py-1.5 text-3xs text-[var(--text-muted)]">
              ${schema.personasRoot ?? ''} · ${schema.handleRules ?? ''}
            </div>
            <div class="max-h-56 overflow-auto" tabindex="0" role="region" aria-label="스키마 필드 목록">
              <table class="w-full text-left text-3xs" aria-label="스키마 필드 카탈로그">
                <thead class="sr-only">
                  <tr>
                    <th scope="col">경로</th>
                    <th scope="col">타입</th>
                    <th scope="col">설명</th>
                  </tr>
                </thead>
                <tbody>
                  ${schema.fieldCatalog.map(field => html`
                    <tr key=${field.path} class="border-b border-[var(--white-6)] align-top">
                      <td class="px-2 py-1.5 font-mono text-[var(--accent)] whitespace-nowrap">${field.path}</td>
                      <td class="px-2 py-1.5 text-[var(--text-muted)]">${field.type ?? ''}${field.required ? ' *' : ''}</td>
                      <td class="px-2 py-1.5 text-[var(--text-body)]">${field.effect ?? ''}</td>
                    </tr>
                  `)}
                </tbody>
              </table>
            </div>
          </div>
        ` : null}
      </div>

      <div class="space-y-3">
        <div class="grid gap-2">
          <div class="flex items-center justify-between">
            <label class="text-3xs text-[var(--text-muted)]" for="persona-profile-json">profile.json</label>
            ${draft ? html`<span class="text-3xs text-[var(--text-muted)]">${draft.handle}</span>` : null}
          </div>
          <textarea autoComplete="off"
            id="persona-profile-json"
            rows=${18}
            value=${profileText.value}
            placeholder="초안을 생성하면 profile.json이 표시됩니다"
            onInput=${(e: Event) => { profileText.value = (e.target as HTMLTextAreaElement).value }}
            class="w-full rounded border border-[var(--white-10)] bg-[var(--bg-0)] px-2 py-2 font-mono text-3xs leading-5 text-[var(--text-body)] placeholder:text-[var(--text-dim)] focus:outline-none focus:border-[var(--accent)] focus-visible:ring-2 focus-visible:ring-[var(--accent)]/50"
          />
        </div>

        ${draft?.fieldExplanations.length ? html`
          <div class="rounded border border-[var(--white-10)] bg-[var(--white-4)]">
            ${draft.fieldExplanations.map(item => html`
              <div key=${item.path} class="grid grid-cols-[minmax(120px,0.35fr)_1fr] gap-2 border-b border-[var(--white-6)] px-2 py-1.5 text-3xs">
                <span class="font-mono text-[var(--accent)]">${item.path}</span>
                <span class="text-[var(--text-body)]">${item.effect ?? prettyValue(item.value)}</span>
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
            <span class="self-center text-3xs text-[var(--text-muted)]">${saveResult.profilePath}</span>
          ` : null}
        </div>

        ${personaAuthoringResult.value ? html`
          <pre class="max-h-48 overflow-auto rounded border border-[var(--white-10)] bg-[var(--white-4)] p-2 text-3xs ${personaAuthoringResult.value.success ? 'text-[var(--text-body)]' : 'text-[var(--bad)]'} leading-[1.4]" tabindex="0" aria-label="페르소나 생성 결과">${personaAuthoringResult.value.message}</pre>
        ` : null}
      </div>
    </div>
  `
}
