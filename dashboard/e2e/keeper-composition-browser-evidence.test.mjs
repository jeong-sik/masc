import assert from 'node:assert/strict'
import test from 'node:test'
import {
  DASHBOARD_KEEPER_READY_TIMEOUT_MS,
  parseExpectedInlineNodes,
  selectCompleteInlineRun,
  waitForKeeperComposerReady,
} from './keeper-composition-browser-evidence.mjs'

const expectedNodes = ['board', 'lane', 'search']
const completeRows = expectedNodes.map(node => ({
  run: 'run-complete',
  node,
  execution: 'inline',
  disposition: 'completed',
}))

test('selects one exact completed inline composition run', () => {
  const selected = selectCompleteInlineRun([
    { run: 'partial', node: 'lane', execution: 'inline', disposition: 'completed' },
    ...completeRows,
  ], expectedNodes)
  assert.equal(selected?.[0], 'run-complete')
  assert.deepEqual(selected?.[1], completeRows)
})
test('rejects duplicate, failed, deferred, and async rows', () => {
  assert.equal(selectCompleteInlineRun([...completeRows, completeRows[0]], expectedNodes), null)
  assert.equal(selectCompleteInlineRun(
    completeRows.map(row => row.node === 'search' ? { ...row, disposition: 'failed' } : row),
    expectedNodes,
  ), null)
  assert.equal(selectCompleteInlineRun(
    completeRows.map(row => row.node === 'search' ? { ...row, disposition: 'deferred' } : row),
    expectedNodes,
  ), null)
  assert.equal(selectCompleteInlineRun(
    completeRows.map(row => ({ ...row, execution: 'async' })),
    expectedNodes,
  ), null)
})

test('rejects a run whose node set differs from the expected one', () => {
  assert.equal(selectCompleteInlineRun(completeRows.slice(1), expectedNodes), null)
  assert.equal(selectCompleteInlineRun(
    completeRows.map(row => row.node === 'search' ? { ...row, node: 'unexpected' } : row),
    expectedNodes,
  ), null)
})

test('parses the runner-owned inline node list', () => {
  assert.deepEqual(parseExpectedInlineNodes('["search","board","lane"]'), ['board', 'lane', 'search'])
  assert.throws(() => parseExpectedInlineNodes('board,lane'), /not JSON/)
  assert.throws(() => parseExpectedInlineNodes('[]'), /distinct non-empty/)
  assert.throws(() => parseExpectedInlineNodes('["board","board"]'), /distinct non-empty/)
  assert.throws(() => parseExpectedInlineNodes('["board",""]'), /distinct non-empty/)
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
