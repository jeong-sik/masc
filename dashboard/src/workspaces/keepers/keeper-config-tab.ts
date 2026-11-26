/**
 * Entity Tab 5: `Config` (`/keepers/:name/config`)
 *
 * - Schema-driven Keeper editor (`/api/v1/config/schema?target=keeper::k`, V2Envelope)
 * - `POST /api/v1/config/patch` `dry_run: true` unified diff preview + CAS `expected_sha256` apply
 *   + `reload_scope` badge (`hot_reload | next_turn | restart_required`) + `409 conflict_cas` handling
 * - Secrets (`POST /api/v1/keepers/:k/secrets`) & OAuth Identity Providers (`/api/v1/keepers/oauth/attached-tools`)
 */

import { html } from 'htm/preact'
import { copyToClipboard } from '../../components/common/copyable-code'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { UnifiedDiffView } from '../../components/common/unified-diff'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { currentSessionEpoch, isEpochCurrent } from '../../core/auth'
import {
  disconnectKeeperOAuth,
  saveKeeperOAuthClient,
  startKeeperGithubDeviceFlow,
  startKeeperOAuthPopupFlow,
  type ActiveKeeperOAuthFlow,
  type KeeperOAuthFlowHandle,
} from '../../core/keeper-oauth-flow'
import {
  fetchConfigSchemaApi,
  patchOpForField,
  postConfigPatchApi,
  type ConfigPatchChange,
  type ConfigPatchResult,
  type ConfigSchemaData,
} from '../../api/config-schema'
import { currentRoute } from '../../routes/router'
import {
  fetchKeeperOAuthAttachedToolsApi,
  mutateKeeperSecretApi,
  refreshKeeperIdentityToolsApi,
  setKeeperIdentitySwitchApi,
} from './keepers-api'
import type {
  KeeperAttachedProvider,
} from './types'

export interface KeeperConfigTabProps {
  readonly keeperName: string
  readonly onMutated: () => void
}

function resolveSectionCategoryId(
  categories: readonly { readonly id: string; readonly title: string }[],
  sectionQuery: string | undefined,
): string | null {
  const raw = sectionQuery?.trim().toLowerCase()
  if (!raw) return null
  const exact = categories.find((c) => c.id.toLowerCase() === raw)
  if (exact) return exact.id
  if (raw === 'sandbox' || raw === 'ssh' || raw === 'docker') {
    const match = categories.find((c) => {
      const hay = `${c.id} ${c.title}`.toLowerCase()
      return hay.includes('sandbox') || hay.includes('ssh') || hay.includes('docker')
    })
    if (match) return match.id
  }
  const partial = categories.find((c) =>
    c.id.toLowerCase().includes(raw) || c.title.toLowerCase().includes(raw),
  )
  return partial?.id ?? null
}

function serializeValue(val: unknown): string {
  if (val === null || val === undefined) return ''
  if (Array.isArray(val)) return val.join(', ')
  return String(val)
}

export function KeeperConfigTab(props: KeeperConfigTabProps) {
  const { keeperName } = props
  const [schema, setSchema] = useState<ConfigSchemaData | null>(null)
  const [activeCategoryId, setActiveCategoryId] = useState<string>('')
  const [drafts, setDrafts] = useState<Record<string, string>>({})
  const [patchResult, setPatchResult] = useState<ConfigPatchResult | null>(null)
  const [configError, setConfigError] = useState<string | null>(null)
  const [casConflict, setCasConflict] = useState(false)
  const [busy, setBusy] = useState(false)

  // Secrets & OAuth Identity state
  const [secretScope, setSecretScope] = useState<'keeper' | 'shared'>('keeper')
  const [secretName, setSecretName] = useState('')
  const [secretValue, setSecretValue] = useState('')
  const [secretStatus, setSecretStatus] = useState<string | null>(null)
  const [providers, setProviders] = useState<readonly KeeperAttachedProvider[]>([])
  const [oauthCallbackUrl, setOauthCallbackUrl] = useState<string | null>(null)
  const [oauthStatus, setOauthStatus] = useState<string | null>(null)
  const [activeOAuthFlow, setActiveOAuthFlow] = useState<ActiveKeeperOAuthFlow | null>(null)
  const [clientDrawer, setClientDrawer] = useState<{
    readonly provider: string
    readonly providerLabel: string
    readonly clientId: string
    readonly clientSecret: string
    readonly scopes: string
  } | null>(null)
  const [clientBusy, setClientBusy] = useState(false)
  const oauthFlowRef = useRef<KeeperOAuthFlowHandle | null>(null)
  const mountedRef = useRef(true)
  const activeKeeperRef = useRef(keeperName)
  const schemaAbortRef = useRef<AbortController | null>(null)
  const providersAbortRef = useRef<AbortController | null>(null)
  const lastAppliedSectionRef = useRef<string | undefined>(undefined)
  activeKeeperRef.current = keeperName

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      oauthFlowRef.current?.cancel()
      schemaAbortRef.current?.abort()
      providersAbortRef.current?.abort()
    }
  }, [])

  const loadSchema = useCallback(async (preservePatchResult = false) => {
    schemaAbortRef.current?.abort()
    const ctrl = new AbortController()
    schemaAbortRef.current = ctrl
    const targetKeeper = keeperName
    const startEpoch = currentSessionEpoch()
    setConfigError(null)
    setCasConflict(false)
    const schemaRes = await fetchConfigSchemaApi(`keeper:${targetKeeper}`, ctrl.signal)
    if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch) || ctrl.signal.aborted) {
      return
    }
    if (!schemaRes.ok) {
      if (schemaRes.error.kind !== 'aborted' && schemaRes.error.kind !== 'epoch_stale') {
        setConfigError(schemaRes.error.message)
      }
      return
    }
    setSchema(schemaRes.value)
    setDrafts({})
    if (!preservePatchResult) {
      setPatchResult(null)
    }
    const routeSection = currentRoute.peek().query.section
    const requestedCat = resolveSectionCategoryId(schemaRes.value.categories, routeSection)
    const firstCat = schemaRes.value.categories[0]?.id ?? ''
    setActiveCategoryId((cur) => {
      if (cur && schemaRes.value.categories.some((c) => c.id === cur)) {
        return cur
      }
      if (requestedCat) {
        lastAppliedSectionRef.current = routeSection
        return requestedCat
      }
      return firstCat
    })
  }, [keeperName])

  const routeSection = currentRoute.value.query.section
  useEffect(() => {
    if (!routeSection) {
      lastAppliedSectionRef.current = undefined
      return
    }
    if (!schema || routeSection === lastAppliedSectionRef.current) return
    const matched = resolveSectionCategoryId(schema.categories, routeSection)
    lastAppliedSectionRef.current = routeSection
    if (matched) setActiveCategoryId(matched)
  }, [schema, routeSection])

  const loadProviders = useCallback(async () => {
    providersAbortRef.current?.abort()
    const ctrl = new AbortController()
    providersAbortRef.current = ctrl
    const targetKeeper = keeperName
    const startEpoch = currentSessionEpoch()
    const provRes = await fetchKeeperOAuthAttachedToolsApi(targetKeeper, ctrl.signal)
    if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch) || ctrl.signal.aborted) {
      return
    }
    if (provRes.ok) {
      setProviders(provRes.value.providers)
      setOauthCallbackUrl(provRes.value.callbackUrl)
    }
  }, [keeperName])

  useEffect(() => {
    oauthFlowRef.current?.cancel()
    schemaAbortRef.current?.abort()
    providersAbortRef.current?.abort()
    setSchema(null)
    setActiveCategoryId('')
    setDrafts({})
    setPatchResult(null)
    setConfigError(null)
    setCasConflict(false)
    setSecretName('')
    setSecretValue('')
    setSecretStatus(null)
    setProviders([])
    setOauthCallbackUrl(null)
    setOauthStatus(null)
    setActiveOAuthFlow(null)
    setClientDrawer(null)
    lastAppliedSectionRef.current = undefined
    void Promise.all([loadSchema(), loadProviders()])
    return () => {
      schemaAbortRef.current?.abort()
      providersAbortRef.current?.abort()
    }
  }, [loadSchema, loadProviders])

  const allFields = useMemo(
    () => (schema ? schema.categories.flatMap((c) => c.fields) : []),
    [schema],
  )

  const activeCategory = useMemo(
    () => schema?.categories.find((c) => c.id === activeCategoryId) ?? schema?.categories[0] ?? null,
    [schema, activeCategoryId],
  )

  const { pendingChanges, invalidFieldKeys } = useMemo(() => {
    const out: ConfigPatchChange[] = []
    const invalid: string[] = []
    for (const field of allFields) {
      if (!field.writable) continue
      const edited = drafts[field.full_key]
      if (edited === undefined) continue
      if (edited === serializeValue(field.current_value)) continue
      const change = patchOpForField(field, edited, false, ',')
      if (change) out.push(change)
      else invalid.push(field.full_key)
    }
    return { pendingChanges: out, invalidFieldKeys: invalid }
  }, [allFields, drafts])

  const runPatch = async (dryRun: boolean) => {
    if (!schema) return
    if (invalidFieldKeys.length > 0) {
      setConfigError(`유효하지 않은 숫자/형식 입력이 있습니다: ${invalidFieldKeys.join(', ')}`)
      return
    }
    if (pendingChanges.length === 0) return
    const targetKeeper = keeperName
    const startEpoch = currentSessionEpoch()
    setBusy(true)
    setConfigError(null)
    setCasConflict(false)
    const res = await postConfigPatchApi({
      target: `keeper:${targetKeeper}`,
      expectedSha256: schema.file_sha256,
      dryRun,
      changes: pendingChanges,
    })
    if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) {
      return
    }
    setBusy(false)
    if (!res.ok) {
      if (res.error.kind === 'conflict_cas' || res.error.status === 409) {
        setCasConflict(true)
      }
      setConfigError(res.error.message)
      return
    }
    setPatchResult(res.value)
    if (!dryRun && res.value.applied) {
      await loadSchema(true)
      if (mountedRef.current && activeKeeperRef.current === targetKeeper && isEpochCurrent(startEpoch)) {
        props.onMutated()
      }
    }
  }

  const handleSaveSecret = async () => {
    const name = secretName.trim()
    if (!name || !secretValue) {
      setSecretStatus('환경변수 이름과 값을 입력하세요.')
      return
    }
    const targetKeeper = keeperName
    const startEpoch = currentSessionEpoch()
    setSecretStatus(null)
    const res = await mutateKeeperSecretApi(targetKeeper, {
      action: 'set_env',
      scope: secretScope,
      name,
      value: secretValue,
    })
    if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) return
    if (!res.ok) {
      setSecretStatus(`저장 실패: ${res.error.message}`)
      return
    }
    setSecretValue('')
    setSecretStatus(`${secretScope}:${name} 시크릿 저장 완료 (값은 재표시되지 않습니다).`)
  }

  const handleDeleteSecret = async () => {
    const name = secretName.trim()
    if (!name) return
    const targetKeeper = keeperName
    const startEpoch = currentSessionEpoch()
    const res = await mutateKeeperSecretApi(targetKeeper, {
      action: 'delete_env',
      scope: secretScope,
      name,
    })
    if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) return
    setSecretStatus(res.ok ? `${secretScope}:${name} 삭제 완료` : `삭제 실패: ${res.error.message}`)
  }

  const renderDiffLines = (diffText: string) =>
    html`<${UnifiedDiffView} diffText=${diffText} inline=${true} />`

  return html`
    <div class="kp-scroll-pane" data-keeper-tab="config">
      <section class="kp-card" aria-label="Schema-Driven Keeper TOML 설정 편집기">
        <div class="kp-card-head">
          <h3>Keeper Config Schema (CAS)</h3>
          <div class="kp-pill-row">
            <span class="kp-pill">sha256: ${schema?.file_sha256.slice(0, 12) || '없음'}</span>
            <span class="kp-pill" data-tone=${pendingChanges.length > 0 ? 'brass' : 'default'}>
              변경 ${pendingChanges.length}건
            </span>
            <button type="button" class="btn-ghost" onClick=${() => void loadSchema()}>스키마 다시 읽기</button>
          </div>
        </div>

        ${casConflict && html`
          <div class="ap-error" role="alert" data-cas-conflict="true">
            CAS 충돌 (409 conflict_cas): 다른 변경이 먼저 적용되었습니다. 스키마를 다시 불러온 뒤 적용하세요.
          </div>
        `}
        ${invalidFieldKeys.length > 0 && html`
          <div class="ap-error" role="alert">
            유효하지 않은 입력 값: ${invalidFieldKeys.join(', ')}
          </div>
        `}
        ${configError && !casConflict && html`<div class="ap-error" role="alert">${configError}</div>`}

        ${schema && html`
          <div class="kp-tabs" role="tablist" aria-label="설정 카테고리">
            ${schema.categories.map((cat) => html`
              <button
                key=${cat.id}
                type="button"
                role="tab"
                class="kp-tab"
                aria-selected=${activeCategory?.id === cat.id ? 'true' : 'false'}
                onClick=${() => setActiveCategoryId(cat.id)}
              >
                ${cat.title} (${cat.field_count})
              </button>
            `)}
          </div>

          ${activeCategory && html`
            <div>
              ${activeCategory.fields.map((field) => {
                const currentText = drafts[field.full_key] ?? serializeValue(field.current_value)
                return html`
                  <div key=${field.full_key} class="kp-field-row">
                    <div>
                      <div class="kp-roster-name">
                        ${field.label ?? field.full_key}
                        <span class="kp-pill" data-tone=${field.reload_scope === 'restart_required' ? 'warn' : 'info'}>
                          ${field.reload_scope}
                        </span>
                      </div>
                      ${field.description && html`<${MarkdownContent} class="kp-roster-sub" text=${field.description} />`}
                      <div class="kp-roster-sub">${field.description ? field.provenance : `${field.type} · ${field.provenance}`}</div>
                    </div>
                    ${!field.writable
                      ? html`<span class="kp-pill">읽기 전용 (${serializeValue(field.current_value) || '없음'})</span>`
                      : field.type === 'bool' || field.type === 'boolean'
                        ? html`
                            <select
                              class="kp-input"
                              aria-label=${field.full_key}
                              value=${currentText || 'false'}
                              onChange=${(e: Event) => setDrafts({ ...drafts, [field.full_key]: (e.currentTarget as HTMLSelectElement).value })}
                            >
                              <option value="true">true</option>
                              <option value="false">false</option>
                            </select>
                          `
                        : field.enum_values && field.enum_values.length > 0
                          ? html`
                              <select
                                class="kp-input"
                                aria-label=${field.full_key}
                                value=${currentText}
                                onChange=${(e: Event) => setDrafts({ ...drafts, [field.full_key]: (e.currentTarget as HTMLSelectElement).value })}
                              >
                                ${field.enum_values.map((v) => html`<option key=${v} value=${v}>${v}</option>`)}
                              </select>
                            `
                          : html`
                              <input
                                type=${field.secret ? 'password' : 'text'}
                                class="kp-input"
                                aria-label=${field.full_key}
                                value=${currentText}
                                onInput=${(e: Event) => setDrafts({ ...drafts, [field.full_key]: (e.currentTarget as HTMLInputElement).value })}
                              />
                            `}
                  </div>
                `
              })}
            </div>
          `}
        `}

        <div class="kp-lifecycle-bar">
          <button
            type="button"
            class="btn-ghost"
            disabled=${busy || pendingChanges.length === 0}
            onClick=${() => void runPatch(true)}
          >
            Dry-Run Unified Diff 미리보기
          </button>
          <button
            type="button"
            class="btn-primary"
            disabled=${busy || pendingChanges.length === 0}
            onClick=${() => void runPatch(false)}
          >
            CAS 설정 적용 (expected_sha256)
          </button>
        </div>

        ${patchResult && html`
          <div>
            <div class="kp-pill-row">
              <span class="kp-pill" data-tone=${patchResult.applied ? 'ok' : 'info'}>
                ${patchResult.applied ? '적용 완료' : 'Dry-Run 미리보기'}
              </span>
              <span class="kp-pill" data-tone=${patchResult.reload_scope === 'restart_required' ? 'warn' : 'brass'}>
                reload_scope: ${patchResult.reload_scope}
              </span>
              ${patchResult.snapshot_id && html`
                <span class="kp-pill">snapshot: ${patchResult.snapshot_id}</span>
              `}
            </div>
            ${patchResult.validation_warnings.map((w, i) => html`
              <div key=${i} class="ap-error sev-warn">⚠ ${w}</div>
            `)}
            <pre class="kp-diff">${renderDiffLines(patchResult.unified_diff)}</pre>
          </div>
        `}
      </section>

      <!-- Secrets & OAuth Identity Section -->
      <div class="kp-grid-2">
        <section class="kp-card" aria-label="Keeper 시크릿 환경변수">
          <div class="kp-card-head">
            <h3>Secrets (Write-Only Env)</h3>
          </div>
          <select
            class="kp-input"
            aria-label="시크릿 범위"
            value=${secretScope}
            onChange=${(e: Event) => setSecretScope((e.currentTarget as HTMLSelectElement).value as 'keeper' | 'shared')}
          >
            <option value="keeper">keeper (${keeperName})</option>
            <option value="shared">shared (workspace)</option>
          </select>
          <input
            type="text"
            class="kp-input"
            placeholder="ENV_VAR_NAME"
            aria-label="시크릿 이름"
            value=${secretName}
            onInput=${(e: Event) => setSecretName((e.currentTarget as HTMLInputElement).value)}
          />
          <input
            type="password"
            class="kp-input"
            placeholder="시크릿 값 (저장 후 재표시되지 않음)"
            aria-label="시크릿 값"
            value=${secretValue}
            onInput=${(e: Event) => setSecretValue((e.currentTarget as HTMLInputElement).value)}
          />
          <div class="kp-lifecycle-bar">
            <button type="button" class="btn-primary" onClick=${() => void handleSaveSecret()}>
              시크릿 저장
            </button>
            <button type="button" class="kp-btn-danger" onClick=${() => void handleDeleteSecret()}>
              시크릿 삭제
            </button>
          </div>
          ${secretStatus && html`<div class="kp-pill" data-tone="info">${secretStatus}</div>`}
        </section>

        <section class="kp-card" aria-label="OAuth 연결 계정 및 도구">
          <div class="kp-card-head">
            <h3>OAuth Identity & Attached Tools</h3>
          </div>
          ${oauthStatus && html`<div class="kp-pill" data-tone="info">${oauthStatus}</div>`}
          ${activeOAuthFlow && html`
            <div class="kp-block-card kp-block-card--tool" data-testid="keeper-config-oauth-flow" role="status">
              <div class="kp-card-head">
                <strong>${activeOAuthFlow.providerLabel} · ${activeOAuthFlow.phase}</strong>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => {
                    oauthFlowRef.current?.cancel()
                    setActiveOAuthFlow(null)
                  }}
                >
                  닫기
                </button>
              </div>
              <div class="kp-roster-sub">${activeOAuthFlow.message}</div>
              <div class="kp-pill-row">
                ${activeOAuthFlow.authorizeUrl && html`
                  <a
                    class="btn-primary"
                    href=${activeOAuthFlow.authorizeUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    OAuth 인증 페이지 열기 ↗
                  </a>
                `}
                ${activeOAuthFlow.deviceCode && html`
                  <span class="kp-pill" data-tone="brass">${activeOAuthFlow.deviceCode}</span>
                `}
              </div>
            </div>
          `}
          ${clientDrawer && html`
            <form
              class="kp-block-card kp-block-card--memory"
              data-testid="keeper-config-oauth-client-form"
              onSubmit=${async (ev: Event) => {
                ev.preventDefault()
                if (!clientDrawer.clientId.trim()) return
                const targetKeeper = keeperName
                const startEpoch = currentSessionEpoch()
                const submittedLabel = clientDrawer.providerLabel
                setClientBusy(true)
                const res = await saveKeeperOAuthClient({
                  provider: clientDrawer.provider,
                  clientId: clientDrawer.clientId,
                  clientSecret: clientDrawer.clientSecret,
                  scopes: clientDrawer.scopes,
                })
                if (!mountedRef.current || activeKeeperRef.current !== targetKeeper || !isEpochCurrent(startEpoch)) return
                setClientBusy(false)
                if (!res.ok) {
                  setOauthStatus(`앱 등록 실패: ${res.error.message}`)
                  return
                }
                setOauthStatus(`${submittedLabel} OAuth 앱 등록 완료`)
                setClientDrawer(null)
                void loadProviders()
              }}
            >
              <div class="kp-card-head">
                <strong>내 OAuth 앱 등록 · ${clientDrawer.providerLabel}</strong>
                <button type="button" class="btn-ghost" onClick=${() => setClientDrawer(null)}>닫기</button>
              </div>
              ${oauthCallbackUrl && html`
                <div class="kp-pill-row" data-testid="keeper-oauth-callback-url" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-2)' }}>
                  <span>Callback URL:</span>
                  <code class="mono" style=${{ overflowWrap: 'anywhere' }}>${oauthCallbackUrl}</code>
                  <button
                    type="button"
                    class="btn-ghost"
                    onClick=${() => {
                      void copyToClipboard(oauthCallbackUrl).then((copied) => {
                        if (!mountedRef.current) return
                        setOauthStatus(copied ? 'Callback URL 복사 완료' : 'Callback URL 복사에 실패했습니다.')
                      })
                    }}
                  >
                    복사
                  </button>
                </div>
              `}
              <input
                type="text"
                class="kp-input"
                aria-label="Keeper OAuth Client ID"
                placeholder="Client ID (필수)"
                required
                value=${clientDrawer.clientId}
                onInput=${(e: Event) => {
                  const clientId = (e.currentTarget as HTMLInputElement).value
                  setClientDrawer((cur) => (cur ? { ...cur, clientId } : null))
                }}
              />
              <input
                type="password"
                class="kp-input"
                aria-label="Keeper OAuth Client Secret"
                placeholder="Client Secret (공개 PKCE 앱은 비워두세요)"
                value=${clientDrawer.clientSecret}
                onInput=${(e: Event) => {
                  const clientSecret = (e.currentTarget as HTMLInputElement).value
                  setClientDrawer((cur) => (cur ? { ...cur, clientSecret } : null))
                }}
              />
              <input
                type="text"
                class="kp-input"
                aria-label="Keeper OAuth Scopes"
                placeholder="Scopes (선택)"
                value=${clientDrawer.scopes}
                onInput=${(e: Event) => {
                  const scopes = (e.currentTarget as HTMLInputElement).value
                  setClientDrawer((cur) => (cur ? { ...cur, scopes } : null))
                }}
              />
              <button type="submit" class="btn-primary" disabled=${clientBusy}>
                ${clientBusy ? '저장 중…' : '앱 저장'}
              </button>
            </form>
          `}
          ${providers.length === 0
            ? html`<div class="kp-empty">연결 가능한 OAuth 공급자 없음</div>`
            : providers.map((prov) => html`
                <div key=${prov.provider} class="kp-field-row">
                  <div>
                    <div class="kp-roster-name">${prov.provider_label}</div>
                    <div class="kp-roster-sub">
                      ${prov.problem
                        ? `⚠ ${prov.problem}`
                        : prov.attached
                          ? `연결됨 · 도구 ${prov.tools?.length ?? 0}개`
                          : '미연결'}
                    </div>
                  </div>
                  <div class="kp-pill-row">
                    ${prov.provider !== 'github' && html`
                      <button
                        type="button"
                        class="btn-ghost"
                        onClick=${() => setClientDrawer({
                          provider: prov.provider,
                          providerLabel: prov.provider_label,
                          clientId: '',
                          clientSecret: '',
                          scopes: '',
                        })}
                      >
                        앱 설정
                      </button>
                    `}
                    ${prov.attached
                      ? html`
                          <button
                            type="button"
                            class="btn-ghost"
                            disabled=${prov.switch_problem != null}
                            onClick=${async () => {
                              const next = !(prov.enabled ?? true)
                              const res = await setKeeperIdentitySwitchApi(keeperName, prov.provider, next)
                              setOauthStatus(res.ok ? `${prov.provider_label} ${next ? '활성화' : '비활성화'}` : res.error.message)
                              void loadProviders()
                            }}
                          >
                            ${prov.enabled === false ? '켜기' : '끄기'}
                          </button>
                          <button
                            type="button"
                            class="btn-ghost"
                            onClick=${async () => {
                              const res = await refreshKeeperIdentityToolsApi(keeperName, prov.provider)
                              setOauthStatus(res.ok ? `${prov.provider_label} 도구 목록 갱신` : res.error.message)
                              void loadProviders()
                            }}
                          >
                            갱신
                          </button>
                          <button
                            type="button"
                            class="kp-btn-danger"
                            onClick=${async () => {
                              const res = await disconnectKeeperOAuth(keeperName, prov.provider)
                              setOauthStatus(res.ok ? `${prov.provider_label} 연결 해제됨` : res.error.message)
                              void loadProviders()
                            }}
                          >
                            해제
                          </button>
                        `
                      : html`
                          <button
                            type="button"
                            class="btn-primary"
                            onClick=${() => {
                              oauthFlowRef.current?.cancel()
                              if (prov.provider === 'github') {
                                oauthFlowRef.current = startKeeperGithubDeviceFlow({
                                  keeper: keeperName,
                                  providerLabel: prov.provider_label,
                                  onUpdate: (st) => {
                                    setActiveOAuthFlow(st)
                                    setOauthStatus(st.message)
                                  },
                                  onSettled: (ok) => {
                                    if (ok) void loadProviders()
                                  },
                                })
                                return
                              }
                              oauthFlowRef.current = startKeeperOAuthPopupFlow({
                                keeper: keeperName,
                                provider: prov.provider,
                                providerLabel: prov.provider_label,
                                onUpdate: (st) => {
                                  setActiveOAuthFlow(st)
                                  setOauthStatus(st.message)
                                },
                                onSettled: (ok) => {
                                  if (ok) void loadProviders()
                                },
                              })
                            }}
                          >
                            연결
                          </button>
                        `}
                  </div>
                </div>
              `)}
        </section>
      </div>
    </div>
  `
}
