import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { h } from 'preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AudioPrefsPanel } from './audio-prefs-panel'

const originalMediaDevices = Object.getOwnPropertyDescriptor(navigator, 'mediaDevices')

afterEach(() => {
  cleanup()
  if (originalMediaDevices) {
    Object.defineProperty(navigator, 'mediaDevices', originalMediaDevices)
  } else {
    Reflect.deleteProperty(navigator, 'mediaDevices')
  }
  vi.unstubAllGlobals()
})

describe('AudioPrefsPanel microphone test', () => {
  it.each(['stop', 'unmount'] as const)('releases a microphone acquired after %s', async cancel => {
    let grant!: (stream: MediaStream) => void
    const getUserMedia = vi.fn(() => new Promise<MediaStream>(resolve => { grant = resolve }))
    Object.defineProperty(navigator, 'mediaDevices', {
      configurable: true,
      value: { getUserMedia, enumerateDevices: vi.fn(async () => []) },
    })
    const AudioContext = vi.fn(function FakeAudioContext() {})
    vi.stubGlobal('AudioContext', AudioContext)

    const stop = vi.fn()
    const view = render(h(AudioPrefsPanel, {}))
    const button = view.getByTestId('mic-test-btn')
    fireEvent.click(button)
    expect(getUserMedia).toHaveBeenCalledTimes(1)

    if (cancel === 'unmount') view.unmount()
    else fireEvent.click(button)
    grant({ getTracks: () => [{ stop }] } as unknown as MediaStream)

    await waitFor(() => expect(stop).toHaveBeenCalledTimes(1))
    expect(AudioContext).not.toHaveBeenCalled()
  })
})
