// namespace-truth-actions.ts retries a cold project snapshot after
// 3s/5s/10s/20s and then at the 30s cap for the remaining attempts. Its
// complete ten-retry budget is 218s, so the real-backend proof must not fail
// at Playwright's 30s default while the product is still inside its declared
// warm-up window. The composer is the user-visible readiness boundary: it is
// rendered only after the selected Keeper exists in the live registry.
export const DASHBOARD_KEEPER_READY_TIMEOUT_MS = 240_000

export async function waitForKeeperComposerReady(page) {
  await page.getByLabel('메시지 입력').waitFor({
    timeout: DASHBOARD_KEEPER_READY_TIMEOUT_MS,
  })
}

// The composition under proof is the acceptance runner's inline fixture, and
// the runner owns its node ids (scripts/harness/workload/
// keeper_multi_collaboration_acceptance.py, INLINE_FIXTURE_NODES). It passes
// them as a JSON array of distinct non-empty strings.
export function parseExpectedInlineNodes(text) {
  let value
  try {
    value = JSON.parse(text)
  } catch (error) {
    throw new Error(`expected inline nodes are not JSON: ${error.message}`)
  }
  if (!Array.isArray(value)
    || value.length === 0
    || !value.every(node => typeof node === 'string' && node.length > 0)
    || new Set(value).size !== value.length) {
    throw new Error(`expected inline nodes must be distinct non-empty strings: ${text}`)
  }
  return [...value].sort()
}

export function selectCompleteInlineRun(rows, expectedNodes) {
  const byRun = new Map()
  for (const row of rows) {
    if (!row.run || !row.node) continue
    const runRows = byRun.get(row.run) ?? []
    runRows.push(row)
    byRun.set(row.run, runRows)
  }
  const expected = JSON.stringify([...expectedNodes].sort())
  return [...byRun.entries()].find(([, runRows]) => {
    const nodes = [...new Set(runRows.map(row => row.node))].sort()
    return runRows.length === expectedNodes.length
      && JSON.stringify(nodes) === expected
      && runRows.every(row => row.execution === 'inline' && row.disposition === 'completed')
  }) ?? null
}
