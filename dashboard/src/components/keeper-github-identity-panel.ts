import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  fetchKeeperGithubIdentity,
  streamKeeperGithubLogin,
  type KeeperGithubIdentityObservation,
} from '../api/dashboard-keeper-github'

interface KeeperGithubIdentityPanelProps {
  keeperName: string
}

function authLabel(authenticated: boolean, login: string | null): string {
  if (!authenticated) return '연결 안 됨'
  return login ? `@${login}` : '연결됨'
}

function extractUrls(text: string): string[] {
  return Array.from(new Set(text.match(/https?:\/\/[^\s<>"']+/g) ?? []))
}

export function KeeperGithubIdentityPanel({
  keeperName,
}: KeeperGithubIdentityPanelProps) {
  const [observation, setObservation] =
    useState<KeeperGithubIdentityObservation | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [loginOpen, setLoginOpen] = useState(false)
  const [loginRunning, setLoginRunning] = useState(false)
  const [output, setOutput] = useState('')
  const abortRef = useRef<AbortController | null>(null)
  const refreshAbortRef = useRef<AbortController | null>(null)

  const refresh = async () => {
    refreshAbortRef.current?.abort()
    const controller = new AbortController()
    refreshAbortRef.current = controller
    setLoadError(null)
    setObservation(null)
    try {
      const next = await fetchKeeperGithubIdentity(
        keeperName,
        'github.com',
        controller.signal,
      )
      if (refreshAbortRef.current === controller) setObservation(next)
    } catch (error) {
      if (!controller.signal.aborted && refreshAbortRef.current === controller) {
        setLoadError(error instanceof Error ? error.message : String(error))
      }
    } finally {
      if (refreshAbortRef.current === controller) refreshAbortRef.current = null
    }
  }

  useEffect(() => {
    void refresh()
    return () => {
      refreshAbortRef.current?.abort()
      abortRef.current?.abort()
    }
  }, [keeperName])

  const urls = useMemo(() => extractUrls(output), [output])

  const startLogin = async () => {
    abortRef.current?.abort()
    const controller = new AbortController()
    abortRef.current = controller
    setLoginOpen(true)
    setLoginRunning(true)
    setOutput('')
    try {
      await streamKeeperGithubLogin(
        keeperName,
        observation?.hostname ?? 'github.com',
        event => {
          if (event.event === 'output') {
            setOutput(current => current + event.text)
          } else if (event.event === 'complete') {
            setObservation(event.observation)
          } else {
            setOutput(current => `${current}\n${event.message}\n`)
          }
        },
        controller.signal,
      )
    } catch (error) {
      if (!controller.signal.aborted) {
        const message = error instanceof Error ? error.message : String(error)
        setOutput(current => `${current}\n${message}\n`)
      }
    } finally {
      if (abortRef.current === controller) abortRef.current = null
      setLoginRunning(false)
    }
  }

  const closeLogin = () => {
    abortRef.current?.abort()
    abortRef.current = null
    setLoginRunning(false)
    setLoginOpen(false)
  }

  return html`
    <section class="kcf-sec">
      <div class="kcf-sec-h">
        <h3>GitHub CLI 계정</h3>
        <div class="ml-auto flex gap-2">
          <button type="button" onClick=${() => void refresh()} class="kcf-btn ghost">새로고침</button>
          <button type="button" onClick=${() => void startLogin()} class="kcf-btn save">GitHub 로그인</button>
        </div>
      </div>
      <p class="kcf-sec-desc">Keeper 전용으로 저장된 GitHub CLI 계정과 호스트에 투영된 자격 증명을 GitHub API로 각각 확인합니다.</p>
      <div class="kcf-sec-body">
        ${loadError && html`<p class="text-2xs text-[var(--color-status-err)]">${loadError}</p>`}
        ${observation && html`
          <div class="kcf-facts">
            <div class="kcf-fact">
              <span class="kcf-fact-k">Keeper 저장소</span>
              <span class="kcf-fact-v mono">${authLabel(observation.stored.authenticated, observation.stored.login)}</span>
              ${observation.stored.error && html`<span class="text-3xs text-[var(--color-status-err)]">확인 실패: ${observation.stored.error}</span>`}
            </div>
            <div class="kcf-fact">
              <span class="kcf-fact-k">호스트 자격 증명 확인</span>
              <span class="kcf-fact-v mono">${authLabel(observation.effective.authenticated, observation.effective.login)}</span>
              <span class="text-3xs text-[var(--color-fg-muted)]">Docker 이미지의 gh·네트워크 동작을 증명하지 않습니다.</span>
              ${observation.effective.error && html`<span class="text-3xs text-[var(--color-status-err)]">확인 실패: ${observation.effective.error}</span>`}
              ${observation.projected_token_env_names.length > 0 && html`
                <span class="text-3xs text-[var(--color-status-warn)]">투영된 토큰 변수: ${observation.projected_token_env_names.join(', ')}</span>
              `}
            </div>
          </div>
        `}
      </div>

      ${loginOpen && html`
        <div class="fixed inset-0 z-50 grid place-items-center bg-slate-950/55 p-4" role="dialog" aria-modal="true" aria-label="GitHub 로그인">
          <div class="w-full max-w-2xl overflow-hidden rounded-2xl border border-slate-700 bg-slate-950 shadow-2xl">
            <div class="flex items-center justify-between border-b border-slate-800 px-4 py-3">
              <div>
                <p class="text-sm font-semibold text-white">${keeperName} GitHub 로그인</p>
                <p class="text-xs text-slate-400">아래 코드와 URL은 gh가 직접 출력한 내용입니다.</p>
              </div>
              <button type="button" onClick=${closeLogin} class="kcf-btn ghost">${loginRunning ? '취소' : '닫기'}</button>
            </div>
            <pre class="max-h-[52vh] min-h-48 overflow-auto whitespace-pre-wrap break-words p-4 font-mono text-xs leading-6 text-emerald-300">${output || 'GitHub 웹 인증 응답을 기다리는 중...'}</pre>
            ${urls.length > 0 && html`
              <div class="flex flex-wrap gap-2 border-t border-slate-800 px-4 py-3">
                ${urls.map(url => html`
                  <a key=${url} href=${url} target="_blank" rel="noreferrer" class="kcf-btn save inline-block no-underline">GitHub 페이지 열기</a>
                `)}
              </div>
            `}
          </div>
        </div>
      `}
    </section>
  `
}
