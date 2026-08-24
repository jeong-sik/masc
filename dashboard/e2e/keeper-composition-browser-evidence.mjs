const EXPECTED_INLINE_NODES = ['board', 'board-peer', 'clock', 'memory']

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

export function selectCompleteInlineRun(rows) {
  const byRun = new Map()
  for (const row of rows) {
    if (!row.run || !row.node) continue
    const runRows = byRun.get(row.run) ?? []
    runRows.push(row)
    byRun.set(row.run, runRows)
  }
  return [...byRun.entries()].find(([, runRows]) => {
    const nodes = [...new Set(runRows.map(row => row.node))].sort()
    return runRows.length === 4
      && JSON.stringify(nodes) === JSON.stringify(EXPECTED_INLINE_NODES)
      && runRows.every(row => row.execution === 'inline' && row.disposition === 'completed')
  }) ?? null
}
