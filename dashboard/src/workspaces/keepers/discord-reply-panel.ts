import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { isEpochCurrent } from '../../core/auth'
import { isUuid, randomUuid } from '../../lib/uuid'
import {
  DISCORD_REPLY_CONTENT_LIMIT,
  discordMessageUrl,
  requestDiscordReply,
  type DiscordReplyAuthority,
  type DiscordReplyReceipt,
  type DiscordReplyTarget,
} from './discord-reply'

type Scope = { readonly authority: DiscordReplyAuthority & { epoch: number }; readonly storageKey: string }
type Operation = { readonly id: string; readonly fingerprint: string | null }
type Attempt = Operation & { readonly content?: string; readonly receipt?: DiscordReplyReceipt }

const STATUS_INTERVAL_MS = 1500
const AUTOMATIC_STATUS_READS = 8

async function fingerprint(id: string, content: string): Promise<string | null> {
  const digest = await globalThis.crypto?.subtle?.digest('SHA-256', new TextEncoder().encode(JSON.stringify([id, content])))
  return digest ? Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('') : null
}

function loadOperation(storageKey: string): Operation | null {
  try {
    const text = sessionStorage.getItem(storageKey)
    if (!text) return null
    const value: unknown = JSON.parse(text)
    if (!value || typeof value !== 'object' || !('id' in value) || !isUuid(value.id) || !('fingerprint' in value)) return null
    if (value.fingerprint !== null && (typeof value.fingerprint !== 'string' || !/^[0-9a-f]{64}$/.test(value.fingerprint))) return null
    return { id: value.id, fingerprint: value.fingerprint }
  } catch {
    return null
  }
}

function keepOperation(storageKey: string, operation: Operation | null): void {
  try {
    if (operation === null) sessionStorage.removeItem(storageKey)
    else sessionStorage.setItem(storageKey, JSON.stringify({ id: operation.id, fingerprint: operation.fingerprint }))
  } catch {
    // Private windows or storage policies can prevent reload recovery.
  }
}

function receiptLabel(receipt: DiscordReplyReceipt): string {
  if (receipt.state === 'sending') return 'Discord 전송 중…'
  if (receipt.state === 'delivered') return 'Discord 전송 완료'
  if (receipt.state === 'outcome_unknown') return 'Discord 전송 여부를 확인할 수 없습니다.'
  if (receipt.state === 'refused') {
    switch (receipt.reason) {
      case 'binding_changed': return '이 대화의 Keeper 바인딩이 바뀌어 전송하지 않았습니다.'
      case 'discord_unconfigured': return 'Discord 봇이 설정되지 않아 전송하지 않았습니다.'
      case 'discord_rejected': return 'Discord에서 답장을 거부했습니다.'
    }
  }
  return 'Discord 전송 상태를 확인할 수 없습니다.'
}

export function DiscordReplyPanel({ target, authority, onClose }: {
  target: DiscordReplyTarget
  authority: Scope['authority']
  onClose: () => void
}) {
  const scope = useMemo<Scope>(() => ({
    authority,
    storageKey: 'masc.discord-reply.' + JSON.stringify([
      authority.actor, authority.workspace.base_path, authority.workspace.masc_root,
      target.keeperName, target.chatId, target.origin.channelId, target.origin.messageId,
    ]),
  }), [authority, target.keeperName, target.chatId, target.origin.channelId, target.origin.messageId])
  const [attempt, setAttempt] = useState<Attempt | null>(() => loadOperation(scope.storageKey))
  const [draft, setDraft] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [pending, setPending] = useState(false)
  const [notObserved, setNotObserved] = useState(false)
  const inputRef = useRef<HTMLTextAreaElement | null>(null)
  const activeRequest = useRef<AbortController | null>(null)
  const automaticReads = useRef(0)

  useEffect(() => () => activeRequest.current?.abort(), [])
  useEffect(() => {
    if (!attempt) inputRef.current?.focus()
  }, [attempt])

  async function run(currentScope: Scope, entry: Attempt, kind: 'send' | 'status', isFirstSend = false) {
    if (activeRequest.current || !isEpochCurrent(currentScope.authority.epoch)) return
    const controller = new AbortController()
    const current = () => !controller.signal.aborted && isEpochCurrent(currentScope.authority.epoch)
    activeRequest.current = controller
    setPending(true)
    setError(null)
    try {
      let admitted = entry
      if (kind === 'send') {
        if (entry.content === undefined) return
        const actualFingerprint = await fingerprint(entry.id, entry.content)
        if (!current()) return
        if (entry.fingerprint !== null && entry.fingerprint !== actualFingerprint) {
          setError('처음 입력한 답장과 내용이 다릅니다.')
          return
        }
        admitted = { ...entry, fingerprint: actualFingerprint }
        if (isFirstSend || entry.fingerprint === null) keepOperation(currentScope.storageKey, admitted)
        setAttempt(admitted)
      }
      const request = kind === 'send' && admitted.content !== undefined
        ? { kind: 'send' as const, content: admitted.content }
        : { kind: 'status' as const }
      const result = await requestDiscordReply(currentScope.authority.workspace, target, admitted.id, request, controller.signal)
      if (!current()) return
      if (result.ok) {
        setNotObserved(false)
        setAttempt({ ...admitted, receipt: result.value })
        if (result.value.state === 'delivered') setDraft('')
        return
      }
      const { status, message } = result.error
      if (isFirstSend && status !== null && [400, 401, 403, 409, 413, 429].includes(status)) {
        keepOperation(currentScope.storageKey, null)
        setAttempt(null)
      }
      if (kind === 'status' && status === 404) {
        setNotObserved(true)
        setError('서버에서 이 작업의 전송 기록을 아직 찾지 못했습니다.')
      } else {
        setError(message)
      }
    } catch (cause) {
      if (current()) setError(cause instanceof Error ? cause.message : 'Discord 전송 결과를 확인할 수 없습니다.')
    } finally {
      if (activeRequest.current === controller) {
        activeRequest.current = null
        if (current()) setPending(false)
      }
    }
  }

  // Query a restored operation once. While Discord still reports sending,
  // follow just this visible operation for a bounded period.
  useEffect(() => {
    if (!attempt || pending || error ||
        (attempt.receipt && attempt.receipt.state !== 'sending') ||
        automaticReads.current >= AUTOMATIC_STATUS_READS) return
    const timer = window.setTimeout(() => {
      automaticReads.current++
      void run(scope, attempt, 'status')
    }, attempt.receipt ? STATUS_INTERVAL_MS : 0)
    return () => window.clearTimeout(timer)
  }, [scope, attempt, pending, error])

  const newReply = () => {
    if (pending || activeRequest.current) return
    keepOperation(scope.storageKey, null)
    automaticReads.current = 0
    setAttempt(null)
    setNotObserved(false)
    setError(null)
  }
  const resumeDraft = notObserved && attempt !== null && !attempt.receipt && attempt.content === undefined
  const receipt = attempt?.receipt
  const terminal = receipt?.state === 'delivered' || receipt?.state === 'refused'
  const tooLong = [...draft].length > DISCORD_REPLY_CONTENT_LIMIT
  const canSend = draft.trim() !== '' && !tooLong && !pending

  return html`
    <form class="kp-discord-reply" aria-label="Discord 답장"
      onSubmit=${(event: Event) => {
        event.preventDefault()
        if (!canSend) return
        if (resumeDraft && attempt) void run(scope, { ...attempt, content: draft }, 'send')
        else if (!attempt) void run(scope, { id: randomUuid(), fingerprint: null, content: draft }, 'send', true)
      }}>
      <div class="kp-msg-head">
        <a href=${discordMessageUrl(target.origin, target.origin.messageId)} target="_blank" rel="noopener noreferrer">Discord 원본</a>
        <button type="button" class="btn-ghost" onClick=${onClose}>닫기</button>
      </div>
      ${(attempt === null || resumeDraft) && html`
        <textarea class="kp-textarea" aria-label="Discord 답장 내용" rows="3" ref=${inputRef}
          value=${draft} onInput=${(event: Event) => setDraft((event.currentTarget as HTMLTextAreaElement).value)} />
        ${tooLong && html`<p role="alert">Discord 답장은 2,000자까지 보낼 수 있습니다.</p>`}
        <button class="btn-primary" type="submit" disabled=${!canSend}>${resumeDraft ? '같은 작업으로 다시 보내기' : 'Discord로 보내기'}</button>
      `}
      ${attempt && html`
        <div role="status">${receipt ? receiptLabel(receipt) : pending ? 'Discord 전송 결과 확인 중…' : 'Discord 전송 결과를 확인할 수 없습니다.'}</div>
        ${receipt?.state === 'delivered' && html`
          <a href=${discordMessageUrl(target.origin, receipt.messageId)} target="_blank" rel="noopener noreferrer">전송한 메시지 열기</a>
        `}
        <div class="kp-pill-row">
          ${terminal && html`<button type="button" class="btn-ghost" disabled=${pending} onClick=${newReply}>새 답장</button>`}
          ${!terminal && html`<button type="button" class="btn-ghost" disabled=${pending}
            onClick=${() => { void run(scope, attempt, 'status') }}>결과 확인</button>`}
          ${!receipt && error && attempt.content !== undefined && html`
            <button type="button" class="btn-ghost" disabled=${pending}
              onClick=${() => { void run(scope, attempt, 'send') }}>같은 요청 다시 보내기</button>
          `}
        </div>
      `}
      ${error && html`<div class="ap-error" role="alert">${error}</div>`}
    </form>
  `
}
