const EXPECTED_INLINE_NODES = ['board', 'board-peer', 'clock', 'memory']

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

