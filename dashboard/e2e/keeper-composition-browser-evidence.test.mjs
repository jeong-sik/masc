import assert from 'node:assert/strict'
import test from 'node:test'
import {
  DASHBOARD_KEEPER_READY_TIMEOUT_MS,
  selectCompleteInlineRun,
  waitForKeeperComposerReady,
} from './keeper-composition-browser-evidence.mjs'

const completeRows = ['board', 'board-peer', 'clock', 'memory'].map(node => ({
  run: 'run-complete',
  node,
  execution: 'inline',
  disposition: 'completed',
}))

test('selects one exact completed inline composition run', () => {
  const selected = selectCompleteInlineRun([
    { run: 'partial', node: 'clock', execution: 'inline', disposition: 'completed' },
    ...completeRows,
  ])
  assert.equal(selected?.[0], 'run-complete')
  assert.deepEqual(selected?.[1], completeRows)
})
test('rejects duplicate, failed, deferred, and async rows', () => {
  assert.equal(selectCompleteInlineRun([...completeRows, completeRows[0]]), null)
  assert.equal(selectCompleteInlineRun(
    completeRows.map(row => row.node === 'memory' ? { ...row, disposition: 'failed' } : row),
  ), null)
  assert.equal(selectCompleteInlineRun(
    completeRows.map(row => row.node === 'memory' ? { ...row, disposition: 'deferred' } : row),
  ), null)
  assert.equal(selectCompleteInlineRun(
    completeRows.map(row => ({ ...row, execution: 'async' })),
  ), null)
})

test('waits through the complete Dashboard project-snapshot warm-up budget', async () => {
  const calls = []
  const page = {
    getByLabel(label) {
      calls.push({ kind: 'label', label })
      return {
        async waitFor(options) {
          calls.push({ kind: 'wait', options })
        },
      }
    },
  }

  await waitForKeeperComposerReady(page)

  assert.deepEqual(calls, [
    { kind: 'label', label: '메시지 입력' },
    { kind: 'wait', options: { timeout: DASHBOARD_KEEPER_READY_TIMEOUT_MS } },
  ])
  assert.ok(DASHBOARD_KEEPER_READY_TIMEOUT_MS > 218_000)
})
