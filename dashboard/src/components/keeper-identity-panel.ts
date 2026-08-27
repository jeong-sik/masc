import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  fetchAttachedProviders,
  isAttachable,
  refreshIdentityTools,
  setIdentityClient,
  setIdentitySwitch,
  startIdentityLogin,
  type AttachedProvider,
  type IdentityLoginStarted,
} from '../api/dashboard-keeper-identity'

interface KeeperIdentityPanelProps {
  keeperName: string
}

function toolSummary(provider: AttachedProvider): string {
  if (!isAttachable(provider)) return ''
  // Three states, not two. "attached and offering nothing" read as "not
  // attached" would tell an operator to consent again for no reason.
  if (!provider.attached) return '연결 안 됨'
  // An unreadable switch store must not render as "on": say so instead.
  if (provider.switch_problem !== undefined) return '연결됨 · 스위치 확인 불가'
  // The switch first: an operator who turned a service off reads that
  // before a tool count that no turn is being handed anyway.
  if (provider.enabled === false) return '연결됨 · 꺼짐'
  const tools = provider.tools ?? []
  return tools.length === 0 ? '연결됨, 도구 없음' : `도구 ${tools.length}개`
}

export function KeeperIdentityPanel({ keeperName }: KeeperIdentityPanelProps) {
  const [providers, setProviders] = useState<AttachedProvider[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [started, setStarted] = useState<IdentityLoginStarted | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [expanded, setExpanded] = useState<string | null>(null)
  const [reloadKey, setReloadKey] = useState(0)
  // Which provider's own-app form is open, and what has been typed into it.
  // Held per provider rather than globally so switching rows does not carry
  // one provider's client id onto another.
  const [ownApp, setOwnApp] = useState<string | null>(null)
  const [ownId, setOwnId] = useState('')
  const [ownSecret, setOwnSecret] = useState('')
  const [ownScopes, setOwnScopes] = useState('')
  const [ownSaved, setOwnSaved] = useState<string | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    setProviders(null)
    setLoadError(null)
    fetchAttachedProviders(keeperName, controller.signal)
      .then(found => {
        if (!controller.signal.aborted) setProviders(found)
      })
      .catch((error: unknown) => {
        if (controller.signal.aborted) return
        setLoadError(error instanceof Error ? error.message : String(error))
      })
    return () => controller.abort()
  }, [keeperName, reloadKey])

  const connect = async (providerId: string) => {
    setBusy(providerId)
    setActionError(null)
    setStarted(null)
    try {
      const answer = await startIdentityLogin(keeperName, providerId)
      setStarted(answer)
      // A pop-up blocker is the common case, so the link stays on the page
      // below rather than this being the only way through.
      window.open(answer.authorize_url, '_blank', 'noreferrer')
    } catch (error) {
      setActionError(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(null)
    }
  }

  const saveOwnApp = async (providerId: string) => {
    setBusy(providerId)
    setActionError(null)
    setOwnSaved(null)
    try {
      const answer = await setIdentityClient(
        providerId,
        ownId,
        ownSecret,
        ownScopes,
      )
      // Cleared on the way out. A secret left in a field is a secret in the
      // page for as long as the tab is open.
      setOwnId('')
      setOwnSecret('')
      setOwnScopes('')
      setOwnApp(null)
      const secretPart = answer.has_client_secret ? '비밀키 포함' : '비밀키 없음'
      const scopePart =
        answer.scopes.length === 0
          ? '권한은 서비스가 내놓는 대로'
          : `권한 ${answer.scopes.length}개`
      setOwnSaved(
        `${answer.provider_label} 앱을 저장했어요 (${secretPart}, ${scopePart})`,
      )
    } catch (error) {
      setActionError(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(null)
    }
  }

  const toggle = async (providerId: string, enabled: boolean) => {
    setBusy(providerId)
    setActionError(null)
    try {
      await setIdentitySwitch(keeperName, providerId, enabled)
      // Re-read rather than patch what is on screen: the switch the server
      // just wrote is the answer.
      setReloadKey(key => key + 1)
    } catch (error) {
      setActionError(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(null)
    }
  }

  const refresh = async (providerId: string) => {
    setBusy(providerId)
    setActionError(null)
    try {
      await refreshIdentityTools(keeperName, providerId)
      // Re-read rather than patch what is on screen: the catalog the server
      // just wrote is the answer.
      setReloadKey(key => key + 1)
    } catch (error) {
      setActionError(error instanceof Error ? error.message : String(error))
    } finally {
      setBusy(null)
    }
  }

  return html`
    <section class="kcf-sec">
      <div class="kcf-sec-h">
        <h3>업무 서비스 연결</h3>
      </div>
      <p class="kcf-sec-desc">
        동의 화면에서 승인하면 토큰이 이 Keeper 전용 시크릿으로 저장되고, 그 서비스의 도구가 이 Keeper 표면에 올라옵니다. 브라우저가 돌아오기 전까지는 아무것도 기록되지 않습니다.
      </p>
      <div class="kcf-sec-body">
        ${loadError && html`<p class="text-2xs text-[var(--color-status-err)]">${loadError}</p>`}
        ${providers === null && !loadError && html`<p class="text-2xs text-[var(--color-fg-muted)]">불러오는 중...</p>`}
        ${providers !== null && providers.length === 0 && html`
          <p class="text-2xs text-[var(--color-fg-muted)]">config/identity/ 에 선언된 서비스가 없습니다.</p>
        `}
        ${providers !== null && providers.length > 0 && html`
          <div class="kcf-facts">
            ${providers.map(provider => html`
              <div class="kcf-fact" key=${provider.provider}>
                ${isAttachable(provider) ? html`
                  <span class="kcf-fact-k">${provider.provider_label}</span>
                  <span class="kcf-fact-v mono">${toolSummary(provider)}</span>
                  <div class="flex gap-2">
                    <button
                      type="button"
                      class="kcf-btn save"
                      disabled=${busy !== null}
                      onClick=${() => void connect(provider.provider)}
                    >${busy === provider.provider ? '여는 중...' : provider.attached ? '다시 연결' : '연결'}</button>
                    ${provider.attached && provider.switch_problem === undefined && html`
                      <button
                        type="button"
                        class="kcf-btn ghost"
                        disabled=${busy !== null}
                        data-testid=${`identity-switch-${provider.provider}`}
                        onClick=${() => void toggle(provider.provider, provider.enabled === false)}
                      >${provider.enabled === false ? '켜기' : '끄기'}</button>
                    `}
                    ${provider.attached && html`
                      <button
                        type="button"
                        class="kcf-btn ghost"
                        disabled=${busy !== null}
                        onClick=${() => void refresh(provider.provider)}
                      >도구 새로고침</button>
                    `}
                    ${provider.attached && (provider.tools?.length ?? 0) > 0 && html`
                      <button
                        type="button"
                        class="kcf-btn ghost"
                        onClick=${() => setExpanded(current => current === provider.provider ? null : provider.provider)}
                      >${expanded === provider.provider ? '접기' : '도구 보기'}</button>
                    `}
                    <button
                      type="button"
                      class="kcf-btn ghost"
                      onClick=${() => {
                        setOwnApp(current => current === provider.provider ? null : provider.provider)
                        setOwnId('')
                        setOwnSecret('')
                        setOwnScopes('')
                      }}
                    >${ownApp === provider.provider ? '접기' : '내 앱 쓰기'}</button>
                  </div>
                  ${ownApp === provider.provider && html`
                    <div class="mt-1 flex flex-col gap-1">
                      <p class="text-3xs text-[var(--color-fg-muted)]">
                        Slack, GitHub, Figma 처럼 앱을 직접 만들어야 하는 서비스에 씁니다. 이 값은 Keeper 하나가 아니라 이 masc 전체가 씁니다.
                      </p>
                      <input
                        class="kcf-input mono"
                        type="text"
                        placeholder="client id"
                        value=${ownId}
                        onInput=${(event: Event) => setOwnId((event.target as HTMLInputElement).value)}
                      />
                      <input
                        class="kcf-input mono"
                        type="password"
                        placeholder="client secret (없으면 비워 두세요)"
                        value=${ownSecret}
                        onInput=${(event: Event) => setOwnSecret((event.target as HTMLInputElement).value)}
                      />
                      <input
                        class="kcf-input mono"
                        type="text"
                        placeholder="scopes (비우면 서비스가 내놓는 전부)"
                        value=${ownScopes}
                        onInput=${(event: Event) => setOwnScopes((event.target as HTMLInputElement).value)}
                      />
                      <button
                        type="button"
                        class="kcf-btn save self-start"
                        disabled=${busy !== null || ownId.trim() === ''}
                        onClick=${() => void saveOwnApp(provider.provider)}
                      >저장</button>
                    </div>
                  `}
                  ${expanded === provider.provider && html`
                    <ul class="mt-1 list-none pl-0 text-3xs text-[var(--color-fg-muted)]">
                      ${(provider.tools ?? []).map(name => html`
                        <li key=${name} class="mono">${provider.provider}_${name}</li>
                      `)}
                    </ul>
                  `}
                ` : html`
                  <span class="kcf-fact-k">${provider.provider}</span>
                  <span class="text-3xs text-[var(--color-status-err)]">선언을 읽을 수 없습니다: ${provider.problem}</span>
                `}
              </div>
            `)}
          </div>
        `}
        ${actionError && html`<p class="text-2xs text-[var(--color-status-err)]">${actionError}</p>`}
        ${ownSaved && html`<p class="text-2xs text-[var(--color-fg-muted)]">${ownSaved}</p>`}
        ${started && html`
          <p class="text-2xs text-[var(--color-fg-muted)]">
            새 창이 열리지 않았다면
            <a href=${started.authorize_url} target="_blank" rel="noreferrer">${started.provider_label} 동의 화면</a>
            을 직접 여세요.
          </p>
        `}
      </div>
    </section>
  `
}
