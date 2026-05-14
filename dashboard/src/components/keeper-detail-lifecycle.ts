import { html } from 'htm/preact'
import { useRef } from 'preact/hooks'
import { requestConfirm } from './common/confirm-dialog'
import { ActionButton } from './common/button'
import { showToast } from './common/toast'
import { refreshAfterRuntimeAction } from './keeper-detail-helpers'
import { bootKeeper, shutdownKeeper } from '../api/keeper'
import type { Keeper } from '../types'
import { DialogOverlay } from './common/dialog'
import { TextArea } from './common/input'
import { Checkbox } from './common/checkbox'

export function KeeperLifecycleButtons({ keeper, effectiveStatus }: { keeper: Keeper; effectiveStatus: string }) {
  const isOffline = ['offline', 'inactive', 'dead', 'crashed', 'unbooted', 'stopped'].includes(effectiveStatus)
  const isRunning = ['active', 'running', 'idle', 'busy', 'listening', 'working'].includes(effectiveStatus)

  if (isOffline) return html`
    <button type="button"
      class="py-1 px-3 rounded-[var(--r-1)] text-2xs font-semibold cursor-pointer border border-[var(--ok-border)] bg-[var(--ok-soft)] text-[var(--color-status-ok)] hover:bg-[var(--ok-soft)] transition-colors"
      onClick=${() => {
        void (async () => {
          try {
            const res = await bootKeeper(keeper.name)
            if (res.ok) {
              showToast(keeper.name + ' 기동됨', 'success')
              await refreshAfterRuntimeAction()
            } else {
              showToast(res.error ?? '기동 실패', 'error')
            }
          } catch {
            showToast('기동 실패', 'error')
          }
        })()
      }}
    >기동</button>`

  if (isRunning) return html`
    <button type="button"
      class="py-1 px-3 rounded-[var(--r-1)] text-2xs font-semibold cursor-pointer border border-[var(--bad-30)] bg-[var(--bad-10)] text-[var(--rose-light)] hover:bg-[var(--bad-soft)] transition-colors"
      onClick=${() => {
        void (async () => {
          const confirmed = await requestConfirm({
            title: '키퍼 종료',
            message: keeper.name + ' 키퍼를 종료합니까?',
            tone: 'danger'
          })
          if (confirmed) {
            try {
              const res = await shutdownKeeper(keeper.name)
              if (res.ok) {
                showToast(keeper.name + ' 종료됨', 'success')
                await refreshAfterRuntimeAction()
              } else {
                showToast(res.error ?? '종료 실패', 'error')
              }
            } catch {
              showToast('종료 실패', 'error')
            }
          }
        })()
      }}
    >종료</button>`

  return null
}

export function KeeperClearContextDialog({
  keeperName,
  open,
  pending,
  reason,
  preserveSystemPrompt,
  onClose,
  onReasonInput,
  onPreserveToggle,
  onSubmit,
}: {
  keeperName: string
  open: boolean
  pending: boolean
  reason: string
  preserveSystemPrompt: boolean
  onClose: () => void
  onReasonInput: (next: string) => void
  onPreserveToggle: (next: boolean) => void
  onSubmit: () => void
}) {
  const reasonRef = useRef<HTMLTextAreaElement>(null)
  const titleId = `keeper-clear-title-${keeperName}`
  const descId = `keeper-clear-desc-${keeperName}`
  if (!open) return null

  return html`
    <${DialogOverlay}
      labelledBy=${titleId}
      describedBy=${descId}
      onClose=${pending ? () => {} : onClose}
      initialFocusRef=${reasonRef}
      overlayClass="fixed inset-0 z-[80] bg-[var(--dialog-overlay-bg)]/70 backdrop-blur-sm isolate flex items-center justify-center p-4"
      panelClass="w-full max-w-130 rounded-[var(--r-1)] border border-[var(--bad-30)] bg-[var(--dialog-panel-bg)] shadow-[var(--shadow-raised)]"
    >
      <div class="p-5 flex flex-col gap-4">
        <div class="flex flex-col gap-1">
          <h3 id=${titleId} class="m-0 text-lg font-semibold text-[var(--color-fg-secondary)]">키퍼 컨텍스트 비우기</h3>
          <p id=${descId} class="m-0 text-sm leading-relaxed text-[var(--color-fg-muted)]">
            ${keeperName}의 checkpoint 대화와 continuity summary를 비웁니다. 사유는 감사 로그에 남습니다.
          </p>
        </div>

        <label class="flex flex-col gap-2">
          <span class="text-2xs font-semibold uppercase tracking-[var(--track-caps)] text-[var(--color-fg-muted)]">사유</span>
          <${TextArea}
            inputRef=${reasonRef}
            class="!bg-[var(--color-bg-surface)] !min-h-[112px] !text-sm leading-paragraph"
            placeholder="예: stale continuity replay 제거"
            ariaLabel="비우기 사유"
            disabled=${pending}
            value=${reason}
            onInput=${(event: Event) => onReasonInput((event.currentTarget as HTMLTextAreaElement).value)}
          />
        </label>

        <label class="flex items-start gap-3 rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] px-3 py-3 text-xs text-[var(--color-fg-primary)]">
          <${Checkbox}
            class="mt-0.5"
            checked=${preserveSystemPrompt}
            disabled=${pending}
            ariaLabel="system prompt 보존"
            onChange=${(checked: boolean) => onPreserveToggle(checked)}
          />
          <span>
            system prompt는 보존하고 나머지 메시지만 비웁니다.
            <span class="block mt-1 text-[var(--color-fg-muted)]">끄면 system prompt까지 같이 제거합니다.</span>
          </span>
        </label>

        <div class="rounded-[var(--r-1)] border border-[var(--warn-24)] bg-[var(--warn-8)] px-3 py-2 text-2xs leading-relaxed text-[var(--color-fg-muted)]">
          마지막 수단용 액션입니다. 잘못된 continuity가 재주입될 때만 쓰고, 실행 후 즉시 상태를 다시 확인하세요.
        </div>

        <div class="flex items-center justify-end gap-2">
          <${ActionButton}
            variant="ghost"
            size="lg"
            disabled=${pending}
            onClick=${onClose}
          >취소<//>
          <button
            type="button"
            class="px-4 py-2 rounded-[var(--r-1)] text-sm font-medium border border-transparent bg-[var(--color-status-err)] text-white hover:bg-[var(--bad-50)] transition-colors cursor-pointer disabled:cursor-not-allowed disabled:opacity-50"
            disabled=${pending || reason.trim() === ''}
            onClick=${onSubmit}
          >${pending ? '비우는 중...' : '비우기'}</button>
        </div>
      </div>
    <//>
  `
}
