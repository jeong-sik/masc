// @vitest-environment jsdom

import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { BoardTypedMediaList } from '../../components/attachments/board-typed-media'
import { decodeBoardPost } from './types'

const SHA = 'c'.repeat(64)

function rawPost(attachments: unknown) {
  return { id: 'post-typed-1', title: '데모', body: '들어보세요', author: 'sangsu', meta: { attachments } }
}

const STORED_WAV = {
  kind: 'audio',
  artifact: { _blob: { sha256: SHA, bytes: 4, mime: 'application/octet-stream', preview: '' } },
  name: 'take-1.wav',
}

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

describe('Board typed audio and MIDI attachments', () => {
  it('decodes audio and midi from meta.attachments and leaves other kinds out', () => {
    const post = decodeBoardPost(rawPost([
      STORED_WAV,
      { kind: 'midi', url: 'https://example.com/theme.mid' },
      { kind: 'image', url: 'https://example.com/a.png' },
      { kind: 'audio', url: 'http://example.com/insecure.mp3' },
    ]))

    expect(post?.typedMedia).toEqual([
      { kind: 'audio', label: 'take-1.wav', source: { kind: 'artifact', sha256: SHA, bytes: 4 } },
      {
        kind: 'midi',
        label: 'https://example.com/theme.mid',
        source: { kind: 'url', url: 'https://example.com/theme.mid' },
      },
    ])
    expect(post?.attachments).toEqual([])
  })

  it('gives a URL audio entry playback controls without fetching it first', () => {
    const fetchSpy = vi.fn()
    vi.stubGlobal('fetch', fetchSpy)
    const post = decodeBoardPost(rawPost([{ kind: 'audio', url: 'https://example.com/a.mp3' }]))

    const view = render(html`<${BoardTypedMediaList} media=${post!.typedMedia} />`)

    const audio = view.container.querySelector('audio')
    expect(audio?.getAttribute('src')).toBe('https://example.com/a.mp3')
    expect(audio?.hasAttribute('controls')).toBe(true)
    expect(audio?.getAttribute('preload')).toBe('none')
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('loads stored audio from the artifact bytes route and then shows controls', async () => {
    const fetchSpy = vi.fn().mockResolvedValue(new Response(new Uint8Array([82, 73, 70, 70])))
    vi.stubGlobal('fetch', fetchSpy)
    vi.stubGlobal('URL', Object.assign(URL, {
      createObjectURL: vi.fn(() => 'blob:stored-audio'),
      revokeObjectURL: vi.fn(),
    }))
    const post = decodeBoardPost(rawPost([STORED_WAV]))

    const view = render(html`<${BoardTypedMediaList} media=${post!.typedMedia} />`)
    fireEvent.click(view.getByText('불러오기'))

    await waitFor(() => {
      expect(view.container.querySelector('audio')?.getAttribute('src')).toBe('blob:stored-audio')
    })
    expect(String(fetchSpy.mock.calls[0]?.[0])).toContain(`/api/v1/artifact-bytes/${SHA}`)
  })

  it('says so when the stored file needs admin', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response('', { status: 403 })))
    const post = decodeBoardPost(rawPost([STORED_WAV]))

    const view = render(html`<${BoardTypedMediaList} media=${post!.typedMedia} />`)
    fireEvent.click(view.getByText('불러오기'))

    await waitFor(() => {
      expect(view.getByRole('alert').textContent).toContain('관리자 로그인')
    })
    expect(view.container.querySelector('audio')).toBeNull()
  })
})
