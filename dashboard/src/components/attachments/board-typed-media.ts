/**
 * Playback for the audio and MIDI entries of a Board post's typed
 * `attachments` argument (`meta.attachments`). These are not workspace
 * attachments: an entry is an https URL or a Tool_blob_store sha256, so they
 * do not go through `<AttachmentGallery>` and its same-origin media paths.
 *
 * - audio: `<audio controls>`. A URL is fetched by the browser only when the
 *   reader presses play (`preload="none"`).
 * - midi: `<MidiScorePlayer>`, after the reader asks for the bytes.
 * - stored bytes: `GET /api/v1/artifact-bytes/<sha256>`, which needs admin.
 *
 * Single-user installations only. The multi-account dashboard does not serve
 * the artifact route, and its CSP (`connect-src 'self'`, no `media-src`)
 * blocks external and blob media, so there the card says it cannot play.
 */

import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import type { BoardTypedMedia } from '../../api/board'
import { buildAttachmentAuthHeaders } from '../../api/attachments'
import { authSession, currentSessionEpoch, resolveWorkspaceUrl, sessionEpoch } from '../../core/auth'
import { MidiScorePlayer } from '../common/alphatab-score'
import { formatAttachmentBytes } from './validation'

async function fetchMediaBytes(source: BoardTypedMedia['source'], signal: AbortSignal): Promise<ArrayBuffer> {
  // The workspace token goes only to this server, never to an external URL.
  const response = source.kind === 'artifact'
    ? await fetch(resolveWorkspaceUrl(`/api/v1/artifact-bytes/${source.sha256}`), {
        credentials: 'same-origin',
        redirect: 'error',
        headers: buildAttachmentAuthHeaders('GET'),
        signal,
      })
    : await fetch(source.url, { credentials: 'omit', referrerPolicy: 'no-referrer', signal })
  if (source.kind === 'artifact' && (response.status === 401 || response.status === 403)) {
    throw new Error('저장된 파일을 열 권한이 없습니다. 관리자 로그인이 필요합니다.')
  }
  if (!response.ok) throw new Error(`파일을 불러오지 못했습니다 (HTTP ${response.status}).`)
  return response.arrayBuffer()
}

function BoardTypedMediaCard({
  media,
  workspaceEpoch,
}: {
  readonly media: BoardTypedMedia
  readonly workspaceEpoch: number
}) {
  const [bytes, setBytes] = useState<Uint8Array | null>(null)
  const [objectUrl, setObjectUrl] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const request = useRef<AbortController | null>(null)

  useEffect(() => () => request.current?.abort(), [])
  useEffect(() => () => {
    if (objectUrl) URL.revokeObjectURL(objectUrl)
  }, [objectUrl])

  if (workspaceEpoch !== sessionEpoch.value) return null

  const { kind, label, source } = media
  const playable = authSession.value.kind !== 'multi_account_signed_in'
  const directUrl = playable && kind === 'audio' && source.kind === 'url' ? source.url : null
  const audioSrc = playable ? directUrl ?? objectUrl : null

  async function load() {
    const controller = new AbortController()
    request.current = controller
    setLoading(true)
    setError(null)
    try {
      const buffer = await fetchMediaBytes(source, controller.signal)
      if (controller.signal.aborted) return
      if (kind === 'midi') setBytes(new Uint8Array(buffer))
      else setObjectUrl(URL.createObjectURL(new Blob([buffer])))
    } catch (cause) {
      if (!controller.signal.aborted) {
        // `fetch` rejects with a TypeError when the request never got an answer (network or CORS).
        setError(cause instanceof Error && !(cause instanceof TypeError)
          ? cause.message
          : '파일을 불러오지 못했습니다. 네트워크나 대상 서버의 CORS 설정을 확인하세요.')
      }
    } finally {
      if (!controller.signal.aborted) setLoading(false)
    }
  }

  const size = source.kind === 'artifact' ? formatAttachmentBytes(source.bytes) : null

  return html`
    <div class="att-card att-audio-card" data-testid=${`board-typed-${kind}`}>
      <div class="att-card-head">
        <span class="att-audio-badge mono">${kind === 'midi' ? 'MIDI' : 'AUDIO'}</span>
        <div class="att-card-info">
          <div class="att-card-title">${label}</div>
          ${size && html`<div class="att-card-meta mono">${size}</div>`}
        </div>
        <div class="att-card-actions">
          ${playable && !audioSrc && !bytes && html`
            <button type="button" class="btn-ghost btn-compact" disabled=${loading} onClick=${load}>
              ${loading ? '불러오는 중…' : '불러오기'}
            </button>
          `}
          ${source.kind === 'url' && html`
            <a class="btn-ghost btn-compact" href=${source.url} target="_blank" rel="noopener noreferrer">원본 열기</a>
          `}
        </div>
      </div>
      ${!playable && html`<div class="att-card-meta">다중 계정 설치에서는 여기서 재생할 수 없습니다.</div>`}
      ${error && html`<div class="ap-error" role="alert">${error}</div>`}
      ${audioSrc && html`
        <audio
          class="att-audio-player"
          controls
          src=${audioSrc}
          preload=${directUrl ? 'none' : 'metadata'}
          onError=${() => {
            setError('브라우저가 이 오디오를 재생하지 못했습니다.')
            // Dropping the blob brings the load button back for another try.
            setObjectUrl(null)
          }}
          onPlaying=${() => setError(null)}
        />
      `}
      ${playable && bytes && html`<${MidiScorePlayer} bytes=${bytes} title=${label} />`}
    </div>
  `
}

export function BoardTypedMediaList({
  media,
  workspaceEpoch = currentSessionEpoch(),
}: {
  readonly media: readonly BoardTypedMedia[]
  readonly workspaceEpoch?: number
}) {
  if (media.length === 0) return null
  return html`
    <div class="att-gallery" data-testid="board-typed-media">
      <div class="att-nonimage-list">
        ${media.map((item, index) => html`
          <${BoardTypedMediaCard}
            key=${`${workspaceEpoch}:${index}:${item.source.kind === 'url' ? item.source.url : item.source.sha256}`}
            media=${item}
            workspaceEpoch=${workspaceEpoch}
          />
        `)}
      </div>
    </div>
  `
}
