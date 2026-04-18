// Auth status indicator with token management popover
// Shows auth state in header and provides token input for remote access

import { html } from 'htm/preact'
import { signal } from '@preact/signals'
import { getStoredToken, setStoredToken, clearStoredToken, isRemoteAccess } from '../api/core'
import { resetMcpClientState } from '../api/mcp'
import { showToast } from './common/toast'

const popoverOpen = signal(false)
const tokenInput = signal('')
const bannerDismissed = signal(false)

export function AuthStatus() {
  const token = getStoredToken()
  const remote = isRemoteAccess()
  const authenticated = Boolean(token)

  const dotColor = authenticated
    ? 'bg-[var(--ok)] shadow-[0_0_6px_rgba(74,222,128,0.6)]'
    : remote
      ? 'bg-[var(--bad)]'
      : 'bg-[var(--warn)]'

  const label = authenticated
    ? '인증됨'
    : remote
      ? '미인증 (원격)'
      : '로컬'

  return html`
    <div class="relative">
      <button type="button"
        class="flex items-center gap-1.5 text-[11px] py-1 px-2 rounded-md border border-solid border-[var(--card-border)] bg-[var(--white-4)] cursor-pointer font-[inherit] transition-colors duration-150 hover:bg-[var(--white-8)] text-[var(--text-muted)]"
        onClick=${() => { popoverOpen.value = !popoverOpen.value }}
        title="인증 상태"
      >
        <span class="size-[7px] rounded-full inline-block ${dotColor}"></span>
        <span>${label}</span>
      </button>
      ${popoverOpen.value ? html`<${AuthPopover} authenticated=${authenticated} />` : null}
    </div>
  `
}

function AuthPopover({ authenticated }: { authenticated: boolean }) {
  const handleSetToken = () => {
    const value = tokenInput.value.trim()
    if (!value) return
    setStoredToken(value)
    resetMcpClientState()
    tokenInput.value = ''
    popoverOpen.value = false
    showToast('토큰이 설정되었습니다.', 'success')
  }

  const handleClearToken = () => {
    clearStoredToken()
    resetMcpClientState()
    popoverOpen.value = false
    showToast('토큰이 제거되었습니다.', 'warning')
  }

  return html`
    <div class="absolute right-0 top-full mt-1.5 w-[280px] rounded-lg border border-[var(--card-border)] bg-[rgba(10,18,34,0.97)] shadow-sm backdrop-blur-xl p-3 z-50">
      ${authenticated ? html`
        <div class="flex flex-col gap-2">
          <div class="text-[11px] text-[var(--text-muted)]">Bearer token이 설정되어 있습니다.</div>
          <button type="button"
            class="w-full py-1.5 px-3 rounded-md text-[11px] border border-[var(--bad-30)] bg-[var(--bad-10)] text-[#fb7185] hover:bg-[rgba(239,68,68,0.15)] cursor-pointer transition-colors"
            onClick=${handleClearToken}
          >토큰 제거</button>
        </div>
      ` : html`
        <div class="flex flex-col gap-2">
          <div class="text-[11px] text-[var(--text-muted)]">Bearer token을 입력하면 원격 환경에서 mutation 작업이 가능합니다.</div>
          <input
            type="password"
            placeholder="Bearer token"
            aria-label="Bearer token"
            class="w-full py-1.5 px-2 rounded-md text-[11px] border border-[var(--card-border)] bg-[var(--white-4)] text-[var(--text-body)] placeholder-[var(--text-muted)] outline-none focus:border-[rgba(71,184,255,0.5)]"
            value=${tokenInput.value}
            onInput=${(e: Event) => { tokenInput.value = (e.target as HTMLInputElement).value }}
            onKeyDown=${(e: KeyboardEvent) => { if (e.key === 'Enter') handleSetToken() }}
          />
          <button type="button"
            class="w-full py-1.5 px-3 rounded-md text-[11px] border border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--accent)] hover:bg-[rgba(71,184,255,0.15)] cursor-pointer transition-colors"
            onClick=${handleSetToken}
          >토큰 설정</button>
        </div>
      `}
    </div>
  `
}

export function RemoteWarningBanner() {
  if (bannerDismissed.value || !isRemoteAccess() || getStoredToken()) return null

  return html`
    <div class="shrink-0 flex items-center justify-between gap-3 px-4 py-2 bg-[var(--warn-10)] border-b border-[rgba(251,191,36,0.2)] text-[12px] text-[var(--warn)]">
      <span>원격 접속이 감지되었습니다. Mutation 작업을 위해 Bearer token을 설정하세요.</span>
      <div class="flex items-center gap-2 shrink-0">
        <button type="button"
          class="px-2 py-0.5 rounded text-[11px] border border-[var(--accent-30)] bg-[var(--accent-10)] text-[var(--accent)] hover:bg-[rgba(71,184,255,0.15)] cursor-pointer transition-colors"
          onClick=${() => { popoverOpen.value = true }}
        >토큰 입력</button>
        <button type="button"
          class="text-[var(--text-muted)] hover:text-[var(--text-body)] cursor-pointer text-[11px] transition-colors"
          onClick=${() => { bannerDismissed.value = true }}
        >\u2715</button>
      </div>
    </div>
  `
}
