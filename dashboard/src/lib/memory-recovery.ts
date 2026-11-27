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

export function buildMemoryRecoveryPayload(input: {
  action: 'resume' | 'adopt' | 'restart_reading' | 'skip_item' | 'skip_line'
  observed?: string
  turnLog?: string
  line?: number
  store?: string
  at?: number
  offset?: number
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
      const line = input.line
      if (!turnLog || line === undefined || !Number.isSafeInteger(line) || line < 0) {
        return err('skip_item 실행에는 turn_log와 0 이상의 line 오프셋이 필요합니다.')
      }
      const store = input.store?.trim() ?? ''
      if (!store && input.at !== undefined) {
        return err('항목 인덱스를 지정하려면 store가 필요합니다.')
      }
      if (store && (input.at === undefined || !Number.isSafeInteger(input.at) || input.at < 0)) {
        return err('head_item 실행에는 0 이상의 항목 인덱스가 필요합니다.')
      }
      if (store && input.at !== undefined) {
        return ok({
          action: 'skip_item',
          target: { kind: 'head_item', turn_log: turnLog, line, store, at: input.at },
        })
      }
      return ok({
        action: 'skip_item',
        target: { kind: 'unreadable_unit', turn_log: turnLog, line },
      })
    }
    case 'skip_line': {
      const offset = input.offset
      if (offset === undefined || !Number.isSafeInteger(offset) || offset < 0) {
        return err('skip_line 실행에는 0 이상의 바이트 offset이 필요합니다.')
      }
      return ok({ action: 'skip_line', offset })
    }
  }
}
