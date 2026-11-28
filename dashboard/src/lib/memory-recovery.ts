import { err, ok, type Result } from './result'

export type MemoryRecoveryActPayload =
  | { readonly action: 'resume' }
  | { readonly action: 'adopt'; readonly observed: string }
  | { readonly action: 'restart_reading'; readonly observed: string }
  | {
      readonly action: 'skip_item'
      readonly target:
        | { readonly kind: 'head_item'; readonly turn_log: string; readonly line: number; readonly store: string; readonly at: number }
        | { readonly kind: 'unreadable_unit'; readonly turn_log: string; readonly line: number }
    }
  | { readonly action: 'skip_line'; readonly offset: number }

function readIndex(value: string | number | undefined): number | null | undefined {
  if (value === undefined) return undefined
  if (typeof value === 'string') {
    const text = value.trim()
    if (text === '') return undefined
    if (!/^\d+$/.test(text)) return null
    value = Number(text)
  }
  return Number.isSafeInteger(value) && value >= 0 ? value : null
}

export function buildMemoryRecoveryPayload(input: {
  action: 'resume' | 'adopt' | 'restart_reading' | 'skip_item' | 'skip_line'
  observed?: string
  turnLog?: string
  line?: string | number
  store?: string
  at?: string | number
  offset?: string | number
}): Result<MemoryRecoveryActPayload, string> {
  switch (input.action) {
    case 'resume':
      return ok({ action: 'resume' })
    case 'adopt': {
      const obs = input.observed?.trim() ?? ''
      if (!obs) return err('adopt 실행에는 snapshot SHA-256(observed) 값이 필요합니다.')
      return ok({ action: 'adopt', observed: obs })
    }
    case 'restart_reading': {
      const obs = input.observed?.trim() ?? ''
      if (!obs) return err('restart_reading 실행에는 turn log ID(observed)가 필요합니다.')
      return ok({ action: 'restart_reading', observed: obs })
    }
    case 'skip_item': {
      const turnLog = input.turnLog?.trim() ?? ''
      const line = readIndex(input.line)
      if (!turnLog || line === undefined || line === null) {
        return err('skip_item 실행에는 turn_log와 0 이상의 line 오프셋이 필요합니다.')
      }
      const store = input.store?.trim() ?? ''
      const at = readIndex(input.at)
      if (!store && at !== undefined) {
        return err('항목 인덱스를 지정하려면 store가 필요합니다.')
      }
      if (store && (at === undefined || at === null)) {
        return err('head_item 실행에는 0 이상의 항목 인덱스가 필요합니다.')
      }
      if (store && at !== undefined && at !== null) {
        return ok({
          action: 'skip_item',
          target: { kind: 'head_item', turn_log: turnLog, line, store, at },
        })
      }
      return ok({
        action: 'skip_item',
        target: { kind: 'unreadable_unit', turn_log: turnLog, line },
      })
    }
    case 'skip_line': {
      const offset = readIndex(input.offset)
      if (offset === undefined || offset === null) {
        return err('skip_line 실행에는 0 이상의 바이트 offset이 필요합니다.')
      }
      return ok({ action: 'skip_line', offset })
    }
  }
}
