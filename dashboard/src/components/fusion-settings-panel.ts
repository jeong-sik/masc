// Fusion settings editor over the typed config API.
//
// Reads GET /api/v1/runtime/config/fusion (the parsed [fusion] policy plus the
// runtime.toml revision it came from) and GET /api/v1/runtime/resolved (the
// lanes and runtimes a preset seat may name), and writes one typed operation at
// a time through POST /api/v1/runtime/config/fusion with that revision as the
// precondition. The server validates the preset, resolves every seat, and
// refuses the write when the file changed since the read; those refusals are
// sentences for a person and are shown as they arrive. The form only rejects
// what it cannot turn into a number.
//
// Drafts: the settings form and the preset form are edited separately and each
// write replaces only the draft it wrote from the refetched config. Reloading
// (the button, or after a conflict) replaces both.
import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import {
  applyFusionConfigEdit,
  fetchFusionConfig,
  fetchRuntimeResolved,
  FusionConfigEditError,
  type FusionConfigEditOperation,
  type FusionConfigSnapshot,
} from '../api/dashboard'
import { errorToString } from '../lib/format-string'
import {
  emptyPresetDraft,
  presetDraftFromView,
  presetFromDraft,
  settingsDraftFromView,
  settingsFromDraft,
  type FusionPresetDraft,
  type FusionSettingsDraft,
} from '../lib/fusion-preset-draft'
import { routeOptionsFromResolved, type FusionRouteOption } from '../lib/fusion-routes'
import { refreshRuntimeConfigConsumers } from '../lib/runtime-config-refresh'
import { runtimeConfigCommitReceiptNotice } from '../lib/runtime-config-receipt'
import { FusionPresetCard } from './fusion/fusion-preset-card'
import { FusionPresetEditor } from './fusion/fusion-preset-editor'

type NoticeSite = 'settings' | 'preset'

type Notice =
  | { readonly kind: 'none' }
  | { readonly kind: 'saved'; readonly site: NoticeSite; readonly text: string }
  | { readonly kind: 'error'; readonly site: NoticeSite; readonly text: string; readonly reloadable: boolean }

interface Loaded {
  readonly config: FusionConfigSnapshot
  readonly routes: readonly FusionRouteOption[]
}

interface PresetSelection {
  /** Name of the saved preset the draft was loaded from; '' when no saved
      preset backs the draft (the config has none yet). */
  readonly loadedName: string
  readonly draft: FusionPresetDraft
}

interface Drafts {
  readonly settings: FusionSettingsDraft
  readonly preset: PresetSelection
}

type PanelState =
  | { readonly phase: 'loading' }
  | { readonly phase: 'failed'; readonly error: string }
  | {
      readonly phase: 'ready'
      readonly loaded: Loaded
      readonly drafts: Drafts
      readonly busy: boolean
      readonly notice: Notice
    }

type Ready = Extract<PanelState, { phase: 'ready' }>

const NO_NOTICE: Notice = { kind: 'none' }
const REVISION_PREVIEW_LENGTH = 12

async function loadAll(): Promise<Loaded> {
  const [config, resolved] = await Promise.all([fetchFusionConfig(), fetchRuntimeResolved()])
  return { config, routes: routeOptionsFromResolved(resolved) }
}

// The preset the editor opens on: the one asked for, else the default, else
// the first, else an empty draft when the config declares none.
function selectPreset(config: FusionConfigSnapshot, preferred: string): PresetSelection {
  const asked = config.presets.find(preset => preset.name === preferred)
  const fallback = config.presets.find(preset => preset.name === config.defaultPreset) ?? config.presets[0]
  const chosen = asked ?? fallback
  return chosen === undefined
    ? { loadedName: '', draft: emptyPresetDraft() }
    : { loadedName: chosen.name, draft: presetDraftFromView(chosen) }
}

function freshDrafts(config: FusionConfigSnapshot, preferredPreset: string): Drafts {
  return { settings: settingsDraftFromView(config), preset: selectPreset(config, preferredPreset) }
}

function readyState(loaded: Loaded, drafts: Drafts, notice: Notice): Ready {
  return { phase: 'ready', loaded, drafts, busy: false, notice }
}

function editFailureNotice(site: NoticeSite, error: unknown): Notice {
  if (error instanceof FusionConfigEditError) {
    return {
      kind: 'error',
      site,
      text: error.failure.message,
      reloadable: error.failure.code === 'configuration_changed',
    }
  }
  return { kind: 'error', site, text: errorToString(error), reloadable: false }
}

function uniqueNames(names: readonly string[]): string[] {
  return names.filter((name, index) => name !== '' && names.indexOf(name) === index)
}

function NoticeView({
  notice,
  site,
  busy,
  onReload,
}: {
  notice: Notice
  site: NoticeSite
  busy: boolean
  onReload: () => void
}) {
  if (notice.kind === 'none' || notice.site !== site) return null
  if (notice.kind === 'saved') {
    return html`<div class="set-line"><span class="set-ok" data-testid="fusion-settings-saved">${notice.text}</span></div>`
  }
  return html`
    <div class="set-line">
      <span class="set-err" data-testid="fusion-settings-error">${notice.text}</span>
      ${notice.reloadable
        ? html`<button type="button" data-testid="fusion-settings-reload" disabled=${busy} onClick=${onReload}>
            다시 불러오기
          </button>`
        : null}
    </div>
  `
}

export function FusionSettingsPanel() {
  const [state, setState] = useState<PanelState>({ phase: 'loading' })
  const mountedRef = useRef(true)

  useEffect(() => {
    mountedRef.current = true
    loadAll()
      .then(loaded => {
        if (!mountedRef.current) return
        setState(readyState(loaded, freshDrafts(loaded.config, loaded.config.defaultPreset), NO_NOTICE))
      })
      .catch((error: unknown) => {
        if (!mountedRef.current) return
        setState({ phase: 'failed', error: errorToString(error) })
      })
    return () => {
      mountedRef.current = false
    }
  }, [])

  if (state.phase === 'loading') {
    return html`<div class="set-hint" data-testid="fusion-settings-loading">설정을 불러오는 중…</div>`
  }
  if (state.phase === 'failed') {
    return html`<div class="set-err" data-testid="fusion-settings-error">${state.error}</div>`
  }

  const ready: Ready = state
  const { loaded, drafts, busy, notice } = ready
  const { settings, preset } = drafts
  const presetNames = loaded.config.presets.map(entry => entry.name)
  const savedPreset = loaded.config.presets.find(entry => entry.name === preset.loadedName)
  const nameChanged = preset.draft.name !== preset.loadedName
  const hasSavedPreset = preset.loadedName !== ''

  const setDrafts = (next: Partial<Drafts>) => {
    // Editing after a write dismisses the stale saved/error banner.
    setState({ ...ready, drafts: { ...drafts, ...next }, notice: NO_NOTICE })
  }
  const patchSettings = (next: Partial<FusionSettingsDraft>) => setDrafts({ settings: { ...settings, ...next } })
  const patchPresetDraft = (draft: FusionPresetDraft) => setDrafts({ preset: { ...preset, draft } })
  const showError = (site: NoticeSite, text: string) => {
    setState({ ...ready, notice: { kind: 'error', site, text, reloadable: false } })
  }

  const reload = async (site: NoticeSite) => {
    setState({ ...ready, busy: true, notice: NO_NOTICE })
    try {
      const next = await loadAll()
      if (!mountedRef.current) return
      setState(readyState(next, freshDrafts(next.config, preset.loadedName), NO_NOTICE))
    } catch (error) {
      if (!mountedRef.current) return
      setState({ ...ready, busy: false, notice: { kind: 'error', site, text: errorToString(error), reloadable: false } })
    }
  }

  // One write: POST with the loaded revision, refetch the config (new
  // revision), let the other dashboard surfaces reload runtime.toml, then
  // replace only the draft this write came from.
  const runEdit = async (
    site: NoticeSite,
    operation: FusionConfigEditOperation,
    draftsAfter: (config: FusionConfigSnapshot) => Drafts,
  ) => {
    setState({ ...ready, busy: true, notice: NO_NOTICE })
    let receiptNotice: string
    try {
      const receipt = await applyFusionConfigEdit(loaded.config.sourceRevision, operation)
      receiptNotice = runtimeConfigCommitReceiptNotice(receipt)
    } catch (error) {
      if (!mountedRef.current) return
      setState({ ...ready, busy: false, notice: editFailureNotice(site, error) })
      return
    }
    let config: FusionConfigSnapshot
    try {
      config = await fetchFusionConfig()
    } catch (error) {
      if (!mountedRef.current) return
      // The write landed but this panel still holds the old revision: the next
      // write would be refused, so say so and offer the reload now.
      setState({
        ...ready,
        busy: false,
        notice: {
          kind: 'error',
          site,
          text: `저장됨 · ${receiptNotice} · 설정을 다시 읽지 못했습니다: ${errorToString(error)}`,
          reloadable: true,
        },
      })
      return
    }
    let nextNotice: Notice = { kind: 'saved', site, text: `저장됨 · ${receiptNotice}` }
    try {
      await refreshRuntimeConfigConsumers()
    } catch (error) {
      nextNotice = {
        kind: 'error',
        site,
        text: `저장됨 · ${receiptNotice} · 대시보드 런타임 갱신 실패: ${errorToString(error)}`,
        reloadable: false,
      }
    }
    if (!mountedRef.current) return
    setState(readyState({ config, routes: loaded.routes }, draftsAfter(config), nextNotice))
  }

  const saveSettings = () => {
    const parsed = settingsFromDraft(settings)
    if (!parsed.ok) {
      showError('settings', parsed.message)
      return
    }
    void runEdit(
      'settings',
      { kind: 'set_settings', ...parsed.value },
      config => ({ settings: settingsDraftFromView(config), preset }),
    )
  }

  const savePreset = () => {
    const parsed = presetFromDraft(preset.draft, preset.loadedName)
    if (!parsed.ok) {
      showError('preset', parsed.message)
      return
    }
    void runEdit(
      'preset',
      { kind: 'upsert_preset', preset: parsed.value },
      config => ({ settings, preset: selectPreset(config, parsed.value.name) }),
    )
  }

  const createPreset = () => {
    if (presetNames.includes(preset.draft.name)) {
      showError('preset', `이미 있는 preset 이름입니다: ${preset.draft.name}`)
      return
    }
    const parsed = presetFromDraft(preset.draft, preset.draft.name)
    if (!parsed.ok) {
      showError('preset', parsed.message)
      return
    }
    void runEdit(
      'preset',
      { kind: 'upsert_preset', preset: parsed.value },
      config => ({ settings, preset: selectPreset(config, parsed.value.name) }),
    )
  }

  const renamePreset = () => {
    if (presetNames.includes(preset.draft.name)) {
      showError('preset', `이미 있는 preset 이름입니다: ${preset.draft.name}`)
      return
    }
    // Only the name travels; the rest of the draft stays as typed so the
    // operator can keep editing and save it under the new name. The settings
    // draft is reread instead: renaming the default preset moves
    // [fusion].default_preset with it, so a kept draft would write the old
    // name back on the next settings save.
    void runEdit(
      'preset',
      { kind: 'rename_preset', from: preset.loadedName, to: preset.draft.name },
      config => ({
        settings: settingsDraftFromView(config),
        preset: { loadedName: preset.draft.name, draft: preset.draft },
      }),
    )
  }

  const deletePreset = () => {
    const confirmed =
      typeof window === 'undefined'
      || typeof window.confirm !== 'function'
      || window.confirm(`preset ${preset.loadedName} 을(를) runtime.toml 에서 지울까요?`)
    if (!confirmed) return
    void runEdit(
      'preset',
      { kind: 'delete_preset', name: preset.loadedName },
      config => ({ settings, preset: selectPreset(config, config.defaultPreset) }),
    )
  }

  const choosePreset = (name: string) => setDrafts({ preset: selectPreset(loaded.config, name) })

  const str = (event: Event) => (event.target as HTMLInputElement).value
  const checked = (event: Event) => (event.target as HTMLInputElement).checked
  const revisionPreview = loaded.config.sourceRevision.slice(0, REVISION_PREVIEW_LENGTH)
  const defaultPresetOptions = uniqueNames([...presetNames, settings.defaultPreset])
  const laneCount = loaded.routes.filter(route => route.kind === 'lane').length

  return html`
    <div class="set-fusion-editor" data-testid="fusion-settings-editor">
      <div class="set-line">
        <span class="set-hint">
          runtime.toml revision <span class="mono" data-testid="fusion-settings-revision">${revisionPreview}</span>
          · route 후보 lane ${laneCount} · runtime ${loaded.routes.length - laneCount}
          · 다시 불러오기는 편집 중인 내용을 버리고 파일의 현재 값으로 바꿉니다.
        </span>
        <button type="button" data-testid="fusion-settings-refresh" disabled=${busy} onClick=${() => void reload('settings')}>
          다시 불러오기
        </button>
      </div>

      <div class="set-sub-h">설정 ([fusion])</div>
      <label class="set-line v2-mobile-operator-target">
        <span>Fusion 심의 활성 (enabled)</span>
        <input type="checkbox" data-testid="fusion-enabled" checked=${settings.enabled} disabled=${busy}
          onChange=${(event: Event) => patchSettings({ enabled: checked(event) })} />
      </label>
      <label class="set-line">
        <span>기본 preset (default_preset)</span>
        <select class="mono" data-testid="fusion-default-preset" value=${settings.defaultPreset} disabled=${busy}
          onChange=${(event: Event) => patchSettings({ defaultPreset: (event.target as HTMLSelectElement).value })}>
          <option value="">미지정</option>
          ${defaultPresetOptions.map(name => html`<option key=${name} value=${name}>${name}</option>`)}
        </select>
      </label>
      <label class="set-line">
        <span>단계형 심판 그룹 크기 (staged_judge_group_size)</span>
        <input type="number" step="1" data-testid="fusion-staged-judge-group-size" value=${settings.stagedJudgeGroupSize}
          disabled=${busy} onInput=${(event: Event) => patchSettings({ stagedJudgeGroupSize: str(event) })} />
      </label>
      <div class="set-line">
        <button type="button" data-testid="fusion-settings-save" disabled=${busy} onClick=${saveSettings}>
          ${busy ? '저장 중…' : '설정 저장'}
        </button>
      </div>
      <${NoticeView} notice=${notice} site="settings" busy=${busy} onReload=${() => void reload('settings')} />

      <div class="set-sub-h">preset</div>
      <label class="set-line">
        <span>편집할 preset</span>
        <select class="mono" data-testid="fusion-preset-select" value=${preset.loadedName} disabled=${busy}
          onChange=${(event: Event) => choosePreset((event.target as HTMLSelectElement).value)}>
          ${hasSavedPreset ? null : html`<option value="">(저장된 preset 없음)</option>`}
          ${presetNames.map(name => html`<option key=${name} value=${name}>${name}</option>`)}
        </select>
      </label>
      <${FusionPresetEditor}
        draft=${preset.draft}
        routes=${loaded.routes}
        disabled=${busy}
        onChange=${patchPresetDraft}
      />
      <div class="set-hint">
        이름을 바꾸면 두 갈래입니다. "이름 바꾸기"는 같은 preset 의 이름만 바꾸고(기본 preset 이면 <span class="mono">default_preset</span> 도 따라갑니다),
        "새 preset"은 지금 내용을 복사해 새 이름으로 만듭니다. "저장"은 불러온 이름 그대로 덮어씁니다.
      </div>
      <div class="set-line set-fusion-actions">
        <button type="button" data-testid="fusion-preset-save" disabled=${busy || !hasSavedPreset || nameChanged}
          onClick=${savePreset}>
          저장
        </button>
        <button type="button" data-testid="fusion-preset-create" disabled=${busy || !nameChanged} onClick=${createPreset}>
          새 preset
        </button>
        <button type="button" data-testid="fusion-preset-rename" disabled=${busy || !hasSavedPreset || !nameChanged}
          onClick=${renamePreset}>
          이름 바꾸기
        </button>
        <button type="button" data-testid="fusion-preset-delete" disabled=${busy || !hasSavedPreset} onClick=${deletePreset}>
          삭제
        </button>
      </div>
      <${NoticeView} notice=${notice} site="preset" busy=${busy} onReload=${() => void reload('preset')} />

      ${savedPreset === undefined
        ? null
        : html`
            <div class="set-sub-h">저장된 구성 요약 · ${savedPreset.name}</div>
            <${FusionPresetCard} preset=${savedPreset} stagedGroupSize=${loaded.config.stagedJudgeGroupSize} />
          `}
    </div>
  `
}
