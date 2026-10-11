// @vitest-environment jsdom
import { h } from 'preact'
import { act } from 'preact/test-utils'
import { render, fireEvent, cleanup, waitFor } from '@testing-library/preact'
import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { ComposerV2 } from './composer-v2'
import { BoardSurface } from './board-surface'
import { operatorSnapshot } from '../../operator-store'
import { boardPosts, boardHearthFilter } from '../../store'
import { boardComposerMode } from './board-state'
import type { OperatorSnapshot } from '../../types'
vi.mock('../../api', () => ({ currentDashboardActor: () => 'test', sendBroadcast: vi.fn(), broadcastReceiptMessage: () => 'receipt', fetchBoardHearths: vi.fn().mockResolvedValue([]), fetchSubBoards: vi.fn().mockResolvedValue([]), fetchBoardFlairs: vi.fn().mockResolvedValue([]) }))
const getUserMedia = vi.fn()
const startRecorder = vi.fn()
const stopTrack = vi.fn()
const stream = { getTracks: () => [{ stop: stopTrack }] } as unknown as MediaStream
beforeEach(() => {
  boardPosts.value = []
  boardHearthFilter.value = ''
  boardComposerMode.value = 'mention'
  operatorSnapshot.value = { root: { paused: false, namespace: 'default' }, sessions: [], keepers: [{ name: 'alpha', status: 'running' }, { name: 'beta', status: 'running' }], recent_messages: [], available_actions: [] } as unknown as OperatorSnapshot
  vi.stubGlobal('fetch', vi.fn().mockImplementation(async () => new Response('[]', { headers: { 'content-type': 'application/json' } })))
  getUserMedia.mockReset(); startRecorder.mockReset(); stopTrack.mockReset()
  vi.stubGlobal('MediaRecorder', class { start = startRecorder })
  Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: { getUserMedia } })
})
afterEach(() => { cleanup(); vi.unstubAllGlobals() })
it('cancels voice capture when the broadcast workspace changes during microphone acquisition', async () => {
  let resolve!: (value: MediaStream) => void
  getUserMedia.mockReturnValue(new Promise(done => { resolve = done }))
  const view = render(h(ComposerV2, { workspaceId: 'ops' }))
  fireEvent.click(view.getByRole('button', { name: 'Start voice input' }))
  expect(getUserMedia).toHaveBeenCalledTimes(1)
  view.rerender(h(ComposerV2, { workspaceId: 'private' }))
  await act(async () => { resolve(stream) })
  expect(startRecorder).not.toHaveBeenCalled()
  expect(stopTrack).toHaveBeenCalledTimes(1)
})
it('cancels voice capture when its broadcast mode changes during acquisition', async () => {
  let resolve!: (value: MediaStream) => void
  getUserMedia.mockReturnValue(new Promise(done => { resolve = done }))
  const view = render(h(ComposerV2, { workspaceId: 'ops', mode: 'broadcast' }))
  fireEvent.click(view.getByRole('button', { name: 'Start voice input' }))
  view.rerender(h(ComposerV2, { workspaceId: 'ops', mode: 'dm' }))
  await act(async () => { resolve(stream) })
  expect(startRecorder).not.toHaveBeenCalled()
  expect(stopTrack).toHaveBeenCalledTimes(1)
})

it('cancels a DM voice request when the selected recipient changes', async () => {
  let resolve!: (value: MediaStream) => void
  getUserMedia.mockReturnValue(new Promise(done => { resolve = done }))
  const view = render(h(ComposerV2, { workspaceId: 'ops', mode: 'dm' }))
  const select = view.getByLabelText('Composer v2 keeper target') as HTMLSelectElement
  await waitFor(() => expect(select.value).toBe('keeper:alpha'))
  fireEvent.click(view.getByRole('button', { name: 'Start voice input' }))
  fireEvent.change(select, { target: { value: 'keeper:beta' } })
  await act(async () => { resolve(stream) })
  expect(select.value).toBe('keeper:beta')
  expect(startRecorder).not.toHaveBeenCalled()
  expect(stopTrack).toHaveBeenCalledTimes(1)
})

it('cancels the mobile microphone request when its composer is collapsed', async () => {
  let resolve!: (value: MediaStream) => void
  getUserMedia.mockReturnValue(new Promise(done => { resolve = done }))
  const view = render(h(BoardSurface, {}))
  fireEvent.click(view.getByTestId('bd-composer-mobile-toggle'))
  fireEvent.click(view.getByTestId('bd-composer-mobile-voice'))
  expect(getUserMedia).toHaveBeenCalledTimes(1)
  fireEvent.click(view.getByTestId('bd-composer-mobile-toggle'))
  await act(async () => { resolve(stream) })
  expect(startRecorder).not.toHaveBeenCalled()
  expect(stopTrack).toHaveBeenCalledTimes(1)
})

it('retains microphone acquisition while ordinary text is edited in the same context', async () => {
  let resolve!: (value: MediaStream) => void
  getUserMedia.mockReturnValue(new Promise(done => { resolve = done }))
  const view = render(h(ComposerV2, { workspaceId: 'ops' }))
  fireEvent.click(view.getByRole('button', { name: 'Start voice input' }))
  fireEvent.input(view.getByLabelText('Composer v2 message'), { target: { value: 'edited text' } })
  await act(async () => { resolve(stream) })
  expect(startRecorder).toHaveBeenCalledTimes(1)
  expect(stopTrack).not.toHaveBeenCalled()
})

it('cancels desktop voice when a typed mention changes the delivery recipient', async () => {
  let resolve!: (value: MediaStream) => void
  getUserMedia.mockReturnValue(new Promise(done => { resolve = done }))
  const view = render(h(ComposerV2, { workspaceId: 'ops', mode: 'dm' }))
  const select = view.getByLabelText('Composer v2 keeper target') as HTMLSelectElement
  await waitFor(() => expect(select.value).toBe('keeper:alpha'))
  fireEvent.click(view.getByRole('button', { name: 'Start voice input' }))
  fireEvent.input(view.getByLabelText('Composer v2 message'), { target: { value: '@beta' } })
  await act(async () => { resolve(stream) })
  expect(select.value).toBe('keeper:alpha')
  expect(startRecorder).not.toHaveBeenCalled()
  expect(stopTrack).toHaveBeenCalledTimes(1)
})

it('cancels mobile voice when a typed mention changes its delivery recipient', async () => {
  let resolve!: (value: MediaStream) => void
  getUserMedia.mockReturnValue(new Promise(done => { resolve = done }))
  const view = render(h(BoardSurface, {}))
  fireEvent.click(view.getByTestId('bd-composer-mobile-toggle'))
  fireEvent.click(view.getByTestId('bd-composer-mobile-voice'))
  expect(getUserMedia).toHaveBeenCalledTimes(1)
  fireEvent.input(view.getByTestId('bd-composer-mobile-body'), { target: { value: '@beta' } })
  await act(async () => { resolve(stream) })
  expect(startRecorder).not.toHaveBeenCalled()
  expect(stopTrack).toHaveBeenCalledTimes(1)
})
