import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { enumerateMicrophones, startMicLevelProbe } from '../../lib/microphone'
import { resetMicrophonePrefs, updateUserPrefs, userPrefs } from '../../lib/user-prefs'

export function MicrophonePrefsPanel(): VNode {
  const prefs = userPrefs.value
  const [devices, setDevices] = useState<MediaDeviceInfo[]>([])
  const [deviceError, setDeviceError] = useState<string | null>(null)
  const [refreshingDevices, setRefreshingDevices] = useState(false)
  const [micTesting, setMicTesting] = useState(false)
  const [micLevel, setMicLevel] = useState(0)
  const [micError, setMicError] = useState<string | null>(null)
  const probeRef = useRef<AbortController | null>(null)

  const refreshDevices = async () => {
    setRefreshingDevices(true)
    setDeviceError(null)
    try {
      setDevices(await enumerateMicrophones())
    } catch (err) {
      setDeviceError(err instanceof Error ? err.message : String(err))
    } finally {
      setRefreshingDevices(false)
    }
  }

  useEffect(() => {
    void refreshDevices()
    return () => {
      probeRef.current?.abort()
      probeRef.current = null
    }
  }, [])

  const handleToggleMicTest = async () => {
    if (probeRef.current) {
      probeRef.current?.abort()
      probeRef.current = null
      setMicTesting(false)
      setMicLevel(0)
      return
    }
    setMicError(null)
    setMicTesting(true)
    const controller = new AbortController()
    probeRef.current = controller
    const handle = await startMicLevelProbe({
      signal: controller.signal,
      onLevel: (rms) => setMicLevel(rms),
      onError: setMicError,
    })
    if (probeRef.current !== controller) {
      handle?.stop()
      return
    }
    if (!handle) {
      probeRef.current = null
      setMicTesting(false)
      return
    }
    void refreshDevices()
  }

  return html`
    <section
      class="wka-card up-panel"
      data-testid="settings-microphone-prefs-panel"
      aria-label="마이크 설정"
    >
      <div class="up-header">
        <div class="up-header-meta">
          <h3 class="up-title">마이크 설정</h3>
          <p class="up-subtitle">채팅 음성 입력과 마이크 테스트에 적용됩니다.</p>
        </div>
        <button
          type="button"
          class="btn-ghost"
          data-testid="mic-reset-btn"
          onClick=${() => resetMicrophonePrefs()}
        >
          마이크 설정 초기화
        </button>
      </div>

      <div class="up-section">
        <div class="up-section-title">
          <span>입력 장치 및 테스트</span>
          <button
            type="button"
            class="btn-ghost"
            disabled=${refreshingDevices}
            onClick=${() => { void refreshDevices() }}
          >
            ${refreshingDevices ? '조회 중…' : '장치 새로고침'}
          </button>
        </div>

        <label class="up-device-row">
          <span class="up-toggle-label">입력 장치 (Microphone)</span>
          <select
            class="up-select"
            aria-label="마이크 입력 장치"
            value=${prefs.inputDeviceId}
            onChange=${(e: Event) => {
              updateUserPrefs({ inputDeviceId: (e.currentTarget as HTMLSelectElement).value })
            }}
          >
            <option value="">시스템 기본값</option>
            ${prefs.inputDeviceId && !devices.some((device) => device.deviceId === prefs.inputDeviceId)
              ? html`<option value=${prefs.inputDeviceId}>선택한 마이크를 찾을 수 없음 (시스템 기본값 사용)</option>`
              : null}
            ${devices.map((dev, index) => html`
              <option key=${dev.deviceId} value=${dev.deviceId}>${dev.label.trim() || `마이크 ${index + 1}`}</option>
            `)}
          </select>
        </label>

        ${deviceError && html`
          <div class="ap-inline-alert ap-inline-alert--warn" role="alert">
            장치 목록 조회 오류: ${deviceError}
          </div>
        `}

        <div class="up-toggle-row">
          <div class="up-vu-wrap">
            <button
              type="button"
              class=${micTesting ? 'btn-primary' : 'btn-ghost'}
              data-testid="mic-test-btn"
              onClick=${() => { void handleToggleMicTest() }}
            >
              ${micTesting ? '마이크 테스트 중지' : '마이크 테스트 시작'}
            </button>
            <div
              class="up-vu-meter"
              role="meter"
              aria-label="마이크 입력 레벨"
              aria-valuemin="0"
              aria-valuemax="100"
              aria-valuenow=${Math.round(micLevel * 100)}
            >
              <div class="up-vu-bar" style=${{ width: `${Math.round(micLevel * 100)}%` }} />
            </div>
            <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)', minWidth: '3ch', textAlign: 'right' }}>
              ${Math.round(micLevel * 100)}%
            </span>
          </div>
        </div>

        ${micError && html`
          <div class="ap-inline-alert ap-inline-alert--warn" role="alert">
            ${micError}
          </div>
        `}

        <div class="up-toggle-list">
          <label class="up-toggle-row">
            <span class="up-toggle-info">
              <span class="up-toggle-label">소음 억제 (Noise Suppression)</span>
              <span class="up-toggle-hint">WebRTC 배경 잡음 필터링</span>
            </span>
            <input
              type="checkbox"
              aria-label="소음 억제"
              checked=${prefs.noiseSuppression}
              onChange=${(e: Event) => {
                updateUserPrefs({ noiseSuppression: (e.currentTarget as HTMLInputElement).checked })
              }}
            />
          </label>

          <label class="up-toggle-row">
            <span class="up-toggle-info">
              <span class="up-toggle-label">에코 제거 (Echo Cancellation)</span>
              <span class="up-toggle-hint">스피커 출력이 마이크로 되돌아오는 현상 억제</span>
            </span>
            <input
              type="checkbox"
              aria-label="에코 제거"
              checked=${prefs.echoCancellation}
              onChange=${(e: Event) => {
                updateUserPrefs({ echoCancellation: (e.currentTarget as HTMLInputElement).checked })
              }}
            />
          </label>

          <label class="up-toggle-row">
            <span class="up-toggle-info">
              <span class="up-toggle-label">자동 게인 제어 (Auto Gain Control)</span>
              <span class="up-toggle-hint">마이크 입력 음량을 일정하게 자동 보정</span>
            </span>
            <input
              type="checkbox"
              aria-label="자동 게인 제어"
              checked=${prefs.autoGainControl}
              onChange=${(e: Event) => {
                updateUserPrefs({ autoGainControl: (e.currentTarget as HTMLInputElement).checked })
              }}
            />
          </label>
        </div>
      </div>

    </section>
  `
}
