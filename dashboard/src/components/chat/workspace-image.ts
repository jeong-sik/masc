import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { sessionEpoch } from '../../core/auth'
import { isWorkspaceMediaPath } from '../../lib/keeper-media'
import {
  acquireWorkspaceMediaObjectUrl,
  type WorkspaceMediaObjectUrlLease,
} from '../../lib/workspace-media-cache'
import { ChatPreviewModal } from '../primitives/chat-preview-modal'

type LoadedMediaState =
  | { readonly path: string; readonly epoch: number; readonly status: 'ready'; readonly lease: WorkspaceMediaObjectUrlLease }
  | { readonly path: string; readonly epoch: number; readonly status: 'error' }

export function WorkspaceChatImage({ path, caption, workspaceEpoch }: {
  path: string
  caption?: string
  workspaceEpoch: number
}) {
  const ref = useRef<HTMLElement>(null)
  const activeLeaseRef = useRef<WorkspaceMediaObjectUrlLease | null>(null)
  const [visible, setVisible] = useState(typeof IntersectionObserver === 'undefined')
  const [attempt, setAttempt] = useState(0)
  const epoch = sessionEpoch.value
  const currentWorkspace = workspaceEpoch === epoch
  const [loaded, setLoaded] = useState<LoadedMediaState | null>(null)
  const [zoomed, setZoomed] = useState(false)

  const releaseActiveLease = () => {
    const previous = activeLeaseRef.current
    activeLeaseRef.current = null
    previous?.release()
  }

  useEffect(() => {
    const figure = ref.current
    if (!currentWorkspace || !figure || typeof IntersectionObserver === 'undefined') return
    const observer = new IntersectionObserver(([entry]) => {
      if (entry?.isIntersecting) {
        setVisible(true)
        observer.disconnect()
      }
    }, {
      rootMargin: '160px',
    })
    observer.observe(figure)
    return () => observer.disconnect()
  }, [currentWorkspace])

  useEffect(() => {
    releaseActiveLease()
    setZoomed(false)
    if (!visible || !currentWorkspace || sessionEpoch.peek() !== epoch || !isWorkspaceMediaPath(path)) {
      return undefined
    }
    const controller = new AbortController()
    void acquireWorkspaceMediaObjectUrl(path, {
      epoch,
      signal: controller.signal,
    }).then((res) => {
      if (controller.signal.aborted || sessionEpoch.peek() !== epoch) {
        if (res.ok) res.value.release()
        return
      }
      if (res.ok) {
        releaseActiveLease()
        activeLeaseRef.current = res.value
        setLoaded({ path, epoch, status: 'ready', lease: res.value })
      } else if (res.error.kind !== 'aborted') {
        setLoaded({ path, epoch, status: 'error' })
      }
    })
    return () => {
      controller.abort()
      releaseActiveLease()
    }
  }, [attempt, currentWorkspace, epoch, path, visible])

  if (!currentWorkspace) return null
  const current = loaded?.path === path && loaded.epoch === epoch ? loaded : null
  const alt = caption || '생성 이미지'
  return html`
    <figure class="img-out" ref=${ref}>
      ${current?.status === 'ready' ? html`
        <div
          class="chat-block-media-frame img-frame cursor-zoom-in"
          role="button"
          tabIndex=${0}
          aria-label=${`${alt} 크게 보기`}
          onClick=${() => setZoomed(true)}
          onKeyDown=${(e: KeyboardEvent) => {
            if (e.isComposing || e.keyCode === 229) return
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault()
              setZoomed(true)
            }
          }}
        >
          <img
            src=${current.lease.url}
            alt=${alt}
            decoding="async"
            class="max-h-96 w-full rounded-[var(--r-1)] object-contain"
            onError=${() => {
              setZoomed(false)
              releaseActiveLease()
              setLoaded({ path, epoch, status: 'error' })
            }}
          />
        </div>
      ` : html`
        <div class="chat-block-media-ph img-ph">
          <span role="status">${current?.status === 'error' ? '이미지를 불러올 수 없습니다' : alt}</span>
          ${current?.status === 'error' && html`
            <button type="button" class="btn-ghost" aria-label="이미지 다시 시도" onClick=${() => {
              setLoaded(null)
              setAttempt(previous => previous + 1)
            }}>다시 시도</button>
          `}
        </div>
      `}
      ${caption && html`<figcaption>${caption}</figcaption>`}
      ${zoomed && current?.status === 'ready' && html`
        <${ChatPreviewModal} title=${alt} onClose=${() => setZoomed(false)}>
          <img
            src=${current.lease.url}
            alt=${alt}
            decoding="async"
            class="max-h-[80vh] max-w-full rounded-[var(--r-1)] object-contain"
          />
        <//>
      `}
    </figure>
  `
}
