/**
 * Discord-Grade Audio, Voice Devices, Sound Cues & Desktop Notifications Panel.
 *
 * Embedded in `/account/profile` so all roles (Worker / Viewer / Admin) can configure
 * client-side audio & notification preferences.
 */

import { html } from 'htm/preact'
import type { VNode } from 'preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import {
  enumerateMediaDevices,
  getDesktopNotificationPermission,
  playSoundCue,
  requestDesktopNotificationPermission,
  startMicLevelProbe,
  type DesktopNotificationPermission,
  type EnumeratedAudioDevices,
} from '../../lib/sound-cues'
import {
  USER_PREFS_LIMITS,
  resetAudioPrefs,
  updateDesktopNotifyPref,
  updateSoundCuePref,
  updateUserPrefs,
  userPrefs,
  type DesktopNotifyEvent,
  type SoundCueEvent,
} from '../../lib/user-prefs'

const SOUND_CUE_META: readonly {
  readonly event: SoundCueEvent
  readonly label: string
  readonly hint: string
}[] = [
  { event: 'approvalPending', label: '도구 승인 요청 (Approval Pending)', hint: 'Keeper가 위험 도구 실행 승인을 요청할 때' },
  { event: 'keeperAsk', label: 'Keeper 질문 (Keeper Ask)', hint: 'Keeper가 사용자 입력이나 결정을 기다릴 때' },
  { event: 'turnCompleted', label: '턴 완료 (Turn Completed)', hint: '긴 에이전트 턴이 정상 완료되었을 때' },
  { event: 'runFailed', label: '실행 실패 (Run Failed)', hint: '워크플로 또는 턴이 오류로 중단되었을 때' },
  { event: 'mention', label: '멘션 알림 (Mention)', hint: '채팅이나 보드에서 내 계정이 호출되었을 때' },
]

const DESKTOP_NOTIFY_META: readonly {
  readonly event: DesktopNotifyEvent
  readonly label: string
  readonly hint: string
}[] = [
  { event: 'approvalPending', label: '승인 대기 데스크톱 알림', hint: '백그라운드 탭에서도 승인 요청 표시' },
  { event: 'keeperAsk', label: 'Keeper 질문 데스크톱 알림', hint: '응답이 필요한 질문 발생 시 알림' },
  { event: 'runFailed', label: '실행 실패 데스크톱 알림', hint: '작업이 실패로 종료되었을 때 즉시 알림' },
]

export function AudioPrefsPanel(): VNode {
  const prefs = userPrefs.value
  const [devices, setDevices] = useState<EnumeratedAudioDevices>({
    inputs: [],
    outputs: [],
    supported: typeof navigator !== 'undefined' && Boolean(navigator.mediaDevices?.enumerateDevices),
  })
  const [refreshingDevices, setRefreshingDevices] = useState(false)
  const [micTesting, setMicTesting] = useState(false)
  const [micLevel, setMicLevel] = useState(0)
  const [micError, setMicError] = useState<string | null>(null)
  const [notifyPerm, setNotifyPerm] = useState<DesktopNotificationPermission>(() =>
    getDesktopNotificationPermission(),
  )
  const probeRef = useRef<AbortController | null>(null)

  const refreshDevices = async () => {
    setRefreshingDevices(true)
    try {
      const result = await enumerateMediaDevices()
      setDevices(result)
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
      deviceId: prefs.inputDeviceId || undefined,
      noiseSuppression: prefs.noiseSuppression,
      echoCancellation: prefs.echoCancellation,
      autoGainControl: prefs.autoGainControl,
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
    }
  }

  const handleRequestNotifyPermission = async () => {
    const next = await requestDesktopNotificationPermission()
    setNotifyPerm(next)
  }

  return html`
    <section
      class="wka-card up-panel"
      data-testid="settings-audio-prefs-panel"
      aria-label="오디오, 음성 장치 및 알림 설정"
    >
      <div class="up-header">
        <div class="up-header-meta">
          <h3 class="up-title">오디오 · 음성 장치 · 알림음</h3>
          <p class="up-subtitle mono">
            volume=${Math.round(prefs.masterVolume * 100)}%
            · ${prefs.muted ? 'muted' : 'active'}
            · tts=${prefs.ttsRate.toFixed(2)}x
            · notify=${notifyPerm}
          </p>
        </div>
        <button
          type="button"
          class="btn-ghost"
          data-testid="audio-reset-btn"
          onClick=${() => resetAudioPrefs()}
        >
          오디오 설정 초기화
        </button>
      </div>

      <!-- Master Volume & Mute -->
      <div class="up-section">
        <div class="up-section-title"><span>마스터 볼륨 및 음소거</span></div>
        <div class="up-slider-list">
          <label class="up-slider-row">
            <div class="up-slider-head">
              <span>마스터 볼륨 (Master Volume)</span>
              <span class="up-slider-value" data-testid="master-volume-value">
                ${prefs.muted ? '음소거됨' : `${Math.round(prefs.masterVolume * 100)}%`}
              </span>
            </div>
            <input
              type="range"
              class="up-range"
              aria-label="마스터 볼륨"
              min=${USER_PREFS_LIMITS.masterVolume.min}
              max=${USER_PREFS_LIMITS.masterVolume.max}
              step=${USER_PREFS_LIMITS.masterVolume.step}
              value=${prefs.masterVolume}
              disabled=${prefs.muted}
              onInput=${(e: Event) => {
                updateUserPrefs({ masterVolume: Number((e.currentTarget as HTMLInputElement).value) })
              }}
            />
          </label>
        </div>

        <div class="up-toggle-list">
          <label class="up-toggle-row">
            <span class="up-toggle-info">
              <span class="up-toggle-label">전체 음소거 (Mute All Sounds)</span>
              <span class="up-toggle-hint">모든 알림음과 효과음 재생을 일시 중지합니다.</span>
            </span>
            <input
              type="checkbox"
              aria-label="전체 음소거"
              checked=${prefs.muted}
              onChange=${(e: Event) => {
                updateUserPrefs({ muted: (e.currentTarget as HTMLInputElement).checked })
              }}
            />
          </label>

          <label class="up-toggle-row">
            <span class="up-toggle-info">
              <span class="up-toggle-label">창이 활성화된 동안 알림음 끄기 (Mute When Focused)</span>
              <span class="up-toggle-hint">현재 MASC 탭을 보고 있을 때는 효과음을 생략합니다.</span>
            </span>
            <input
              type="checkbox"
              aria-label="창 활성화 시 음소거"
              checked=${prefs.muteWhenFocused}
              onChange=${(e: Event) => {
                updateUserPrefs({ muteWhenFocused: (e.currentTarget as HTMLInputElement).checked })
              }}
            />
          </label>
        </div>
      </div>

      <!-- Audio Devices & Live Mic Test -->
      <div class="up-section">
        <div class="up-section-title">
          <span>입력 / 출력 장치 & 마이크 테스트</span>
          <button
            type="button"
            class="btn-ghost"
            disabled=${refreshingDevices}
            onClick=${() => { void refreshDevices() }}
          >
            ${refreshingDevices ? '조회 중…' : '장치 새로고침'}
          </button>
        </div>

        <div class="up-grid-2">
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
              <option value="">시스템 기본값 (System Default)</option>
              ${devices.inputs.map((dev) => html`
                <option key=${dev.deviceId} value=${dev.deviceId}>${dev.label}</option>
              `)}
            </select>
          </label>

          <label class="up-device-row">
            <span class="up-toggle-label">출력 장치 (Speaker / Headphones)</span>
            <select
              class="up-select"
              aria-label="스피커 출력 장치"
              value=${prefs.outputDeviceId}
              onChange=${(e: Event) => {
                updateUserPrefs({ outputDeviceId: (e.currentTarget as HTMLSelectElement).value })
              }}
            >
              <option value="">시스템 기본값 (System Default)</option>
              ${devices.outputs.map((dev) => html`
                <option key=${dev.deviceId} value=${dev.deviceId}>${dev.label}</option>
              `)}
            </select>
          </label>
        </div>

        ${devices.error && html`
          <div class="ap-inline-alert ap-inline-alert--warn" role="alert">
            장치 목록 조회 오류: ${devices.error}
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

      <!-- TTS Playback -->
      <div class="up-section">
        <div class="up-section-title"><span>음성 합성 (TTS) 재생</span></div>
        <div class="up-toggle-list">
          <label class="up-toggle-row">
            <span class="up-toggle-info">
              <span class="up-toggle-label">TTS 자동 재생 (TTS Autoplay)</span>
              <span class="up-toggle-hint">Keeper 응답이 도착하면 자동으로 음성 재생</span>
            </span>
            <input
              type="checkbox"
              aria-label="TTS 자동 재생"
              checked=${prefs.ttsAutoplay}
              onChange=${(e: Event) => {
                updateUserPrefs({ ttsAutoplay: (e.currentTarget as HTMLInputElement).checked })
              }}
            />
          </label>
        </div>
        <label class="up-slider-row">
          <div class="up-slider-head">
            <span>TTS 재생 속도 (Playback Speed)</span>
            <span class="up-slider-value" data-testid="tts-rate-value">${prefs.ttsRate.toFixed(2)}x</span>
          </div>
          <input
            type="range"
            class="up-range"
            aria-label="TTS 재생 속도"
            min=${USER_PREFS_LIMITS.ttsRate.min}
            max=${USER_PREFS_LIMITS.ttsRate.max}
            step=${USER_PREFS_LIMITS.ttsRate.step}
            value=${prefs.ttsRate}
            onInput=${(e: Event) => {
              updateUserPrefs({ ttsRate: Number((e.currentTarget as HTMLInputElement).value) })
            }}
          />
        </label>
      </div>

      <!-- Per-Event Sound Cues -->
      <div class="up-section">
        <div class="up-section-title"><span>이벤트별 알림음 (Sound Cues)</span></div>
        <div class="up-toggle-list">
          ${SOUND_CUE_META.map((item) => html`
            <div key=${item.event} class="up-toggle-row">
              <label class="up-toggle-info" style=${{ cursor: 'pointer', flex: '1 1 auto' }}>
                <span class="up-toggle-label">${item.label}</span>
                <span class="up-toggle-hint">${item.hint}</span>
              </label>
              <div class="up-cue-actions">
                <button
                  type="button"
                  class="btn-ghost"
                  data-test-cue=${item.event}
                  onClick=${() => {
                    playSoundCue(item.event, { force: true })
                  }}
                >
                  테스트
                </button>
                <input
                  type="checkbox"
                  aria-label=${item.label}
                  checked=${prefs.soundCues[item.event]}
                  onChange=${(e: Event) => {
                    updateSoundCuePref(item.event, (e.currentTarget as HTMLInputElement).checked)
                  }}
                />
              </div>
            </div>
          `)}
        </div>
      </div>

      <!-- Desktop Notifications -->
      <div class="up-section">
        <div class="up-section-title">
          <span>데스크톱 알림 (Desktop Notifications)</span>
          <div class="up-cue-actions">
            <span class="mono" style=${{ fontSize: 'var(--fs-11)', color: 'var(--fg-3)' }}>
              권한: ${notifyPerm}
            </span>
            ${notifyPerm !== 'granted' && notifyPerm !== 'unsupported' && html`
              <button
                type="button"
                class="btn-ghost"
                data-testid="request-notify-perm-btn"
                onClick=${() => { void handleRequestNotifyPermission() }}
              >
                권한 요청
              </button>
            `}
          </div>
        </div>
        <div class="up-toggle-list">
          ${DESKTOP_NOTIFY_META.map((item) => html`
            <label key=${item.event} class="up-toggle-row">
              <span class="up-toggle-info">
                <span class="up-toggle-label">${item.label}</span>
                <span class="up-toggle-hint">${item.hint}</span>
              </span>
              <input
                type="checkbox"
                aria-label=${item.label}
                checked=${prefs.desktopNotify[item.event]}
                onChange=${(e: Event) => {
                  updateDesktopNotifyPref(item.event, (e.currentTarget as HTMLInputElement).checked)
                }}
              />
            </label>
          `)}
        </div>
      </div>
    </section>
  `
}
