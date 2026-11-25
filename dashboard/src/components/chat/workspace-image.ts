import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { fetchWithTimeout } from '../../api/core'
import { DEFAULT_GET_TIMEOUT_MS } from '../../config/constants'
import { authSession, getSingleUserToken, resolveWorkspaceUrl, sessionEpoch } from '../../core/auth'
import { isWorkspaceMediaPath, isWorkspaceRasterMime } from '../../lib/keeper-media'
import { parseUrl } from '../../lib/parse-url'

// Match the default limit of the Keeper generated-media store.
const MAX_IMAGE_BYTES = 10 * 1024 * 1024

async function readImage(response: Response): Promise<Blob | null> {
  const contentType = response.headers.get('content-type')?.split(';', 1)[0]?.trim()
  if (!response.ok || !isWorkspaceRasterMime(contentType)
    || Number(response.headers.get('content-length')) > MAX_IMAGE_BYTES
    || !response.body) {
    await response.body?.cancel()
    return null
  }
  const reader = response.body.getReader()
  const chunks: ArrayBuffer[] = []
  let size = 0
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) return size > 0 ? new Blob(chunks, { type: contentType }) : null
      size += value.byteLength
      if (size > MAX_IMAGE_BYTES) {
        await reader.cancel()
        return null
      }
      chunks.push(value.slice().buffer)
    }
  } finally {
    reader.releaseLock()
  }
}

function dataUrl(image: Blob): Promise<string | null> {
  return new Promise(resolve => {
    const reader = new FileReader()
    reader.onload = () => resolve(typeof reader.result === 'string' ? reader.result : null)
    reader.onerror = () => resolve(null)
    reader.readAsDataURL(image)
  })
}

export function WorkspaceChatImage({ path, caption, workspaceEpoch }: {
  path: string
  caption?: string
  workspaceEpoch: number
}) {
  const ref = useRef<HTMLElement>(null)
  const [visible, setVisible] = useState(typeof IntersectionObserver === 'undefined')
  const [attempt, setAttempt] = useState(0)
  const epoch = sessionEpoch.value
  const currentWorkspace = workspaceEpoch === epoch
  const [loaded, setLoaded] = useState<{ path: string; epoch: number; src: string | null } | null>(null)

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
    if (!visible || !currentWorkspace || sessionEpoch.peek() !== epoch || !isWorkspaceMediaPath(path)) return
    const destination = parseUrl(resolveWorkspaceUrl(path), window.location.origin)
    if (!destination || destination.origin !== window.location.origin) {
      setLoaded({ path, epoch, src: null })
      return
    }
    const controller = new AbortController()
    const token = authSession.peek().kind === 'multi_account_signed_in' ? null : getSingleUserToken()
    const store = (src: string | null) => {
      if (!controller.signal.aborted && sessionEpoch.peek() === epoch) {
        setLoaded({ path, epoch, src })
      }
    }
    void fetchWithTimeout(
      destination.href,
      {
        credentials: 'same-origin',
        mode: 'same-origin',
        redirect: 'error',
        signal: controller.signal,
        headers: token ? { Authorization: `Bearer ${token}` } : undefined,
      },
      DEFAULT_GET_TIMEOUT_MS,
      readImage,
    ).then(image => image ? dataUrl(image) : null).then(store, () => store(null))
    return () => controller.abort()
  }, [attempt, currentWorkspace, epoch, path, visible])

  if (!currentWorkspace) return null
  const current = loaded?.path === path && loaded.epoch === epoch ? loaded : null
  const alt = caption || '생성 이미지'
  return html`
    <figure class="img-out" ref=${ref}>
      ${current?.src ? html`
        <img src=${current.src} alt=${alt} class="max-h-96 w-full rounded-[var(--r-1)] object-contain"
          onError=${() => setLoaded({ path, epoch, src: null })} />
      ` : html`
        <div class="chat-block-media-ph img-ph">
          <span role="status">${current ? '이미지를 불러올 수 없습니다' : alt}</span>
          ${current && html`
            <button type="button" class="btn btn-sm" aria-label="이미지 다시 시도" onClick=${() => {
              setLoaded(null)
              setAttempt(previous => previous + 1)
            }}>다시 시도</button>
          `}
        </div>
      `}
      ${caption && html`<figcaption>${caption}</figcaption>`}
    </figure>
  `
}
