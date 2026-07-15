import { beforeEach, describe, expect, it } from 'vitest'

import {
  _resetLiveSendRunOwnersForTests,
  activeStreamRunRef,
  claimLiveSendRun,
  liveSendOwnsRun,
  releaseLiveSendRun,
} from './keeper-state'
import type { KeeperRunRef } from './lib/keeper-run-ref'

function runRef(keeperName: string, runId: string): KeeperRunRef {
  return {
    runId,
    target: { kind: 'keeper', name: keeperName },
    capability: 'invoke_turn',
  }
}

describe('live Keeper run ownership', () => {
  beforeEach(_resetLiveSendRunOwnersForTests)

  it('replaces only the previous exact run for the same Keeper', () => {
    const first = runRef('echo', 'run-1')
    const second = runRef('echo', 'run-2')

    claimLiveSendRun(first)
    claimLiveSendRun(second)

    expect(liveSendOwnsRun(first)).toBe(false)
    expect(liveSendOwnsRun(second)).toBe(true)
    expect(activeStreamRunRef('echo')).toEqual(second)
    expect(releaseLiveSendRun(first)).toBe(false)
    expect(activeStreamRunRef('echo')).toEqual(second)
  })

  it('keeps equal run ids for different Keepers isolated by full identity', () => {
    const echo = runRef('echo', 'shared-id')
    const luna = runRef('luna', 'shared-id')

    claimLiveSendRun(echo)
    claimLiveSendRun(luna)

    expect(activeStreamRunRef('echo')).toEqual(echo)
    expect(activeStreamRunRef('luna')).toEqual(luna)
    releaseLiveSendRun(echo)
    expect(liveSendOwnsRun(echo)).toBe(false)
    expect(liveSendOwnsRun(luna)).toBe(true)
  })
})
