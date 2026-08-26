import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  fetchIdentityProviders,
  isConnectable,
  startIdentityLogin,
  type IdentityLoginStarted,
  type IdentityProvider,
} from '../api/dashboard-keeper-identity'

interface KeeperIdentityPanelProps {
  keeperName: string
}

export function KeeperIdentityPanel({ keeperName }: KeeperIdentityPanelProps) {
  const [providers, setProviders] = useState<IdentityProvider[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [starting, setStarting] = useState<string | null>(null)
  const [started, setStarted] = useState<IdentityLoginStarted | null>(null)
  const [startError, setStartError] = useState<string | null>(null)

  useEffect(() => {
    const controller = new AbortController()
    setProviders(null)
    setLoadError(null)
    setStarted(null)
    setStartError(null)
    fetchIdentityProviders(controller.signal)
      .then(found => {
        if (!controller.signal.aborted) setProviders(found)
      })
      .catch((error: unknown) => {
        if (controller.signal.aborted) return
        setLoadError(error instanceof Error ? error.message : String(error))
      })
    return () => controller.abort()
  }, [keeperName])

  const connect = async (providerId: string) => {
    setStarting(providerId)
    setStartError(null)
    setStarted(null)
    try {
      const answer = await startIdentityLogin(keeperName, providerId)
      setStarted(answer)
      // A pop-up blocker is the common case here, so the link stays on the
      // page below rather than this being the only way through.
      window.open(answer.authorize_url, '_blank', 'noreferrer')
    } catch (error) {
      setStartError(error instanceof Error ? error.message : String(error))
    } finally {
      setStarting(null)
    }
  }

  return html`
    <section class="kcf-sec">
      <div class="kcf-sec-h">
        <h3>업무 서비스 연결</h3>
      </div>
      <p class="kcf-sec-desc">
        동의 화면에서 승인하면 토큰이 이 Keeper 전용 시크릿으로 저장됩니다. 브라우저가 돌아오기 전까지는 아무것도 기록되지 않습니다.
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
              <div class="kcf-fact" key=${provider.id}>
                <span class="kcf-fact-k">${isConnectable(provider) ? provider.label : provider.id}</span>
                ${isConnectable(provider) ? html`
                  <button
                    type="button"
                    class="kcf-btn save"
                    disabled=${starting !== null}
                    onClick=${() => void connect(provider.id)}
                  >${starting === provider.id ? '여는 중...' : '연결'}</button>
                ` : html`
                  <span class="text-3xs text-[var(--color-status-err)]">선언을 읽을 수 없습니다: ${provider.problem}</span>
                `}
              </div>
            `)}
          </div>
        `}
        ${startError && html`<p class="text-2xs text-[var(--color-status-err)]">${startError}</p>`}
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
