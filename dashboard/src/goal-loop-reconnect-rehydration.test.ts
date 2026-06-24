import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'

// RFC-0284 §6 — goal-loop reconnect re-hydration.
//
// After an SSE reconnect the goal-loop panel must recover via the existing
// dashboard refresh, NOT a dedicated goal-loop fetch. The load-bearing chain is:
//
//   handleReconnect (sse-store.ts)
//     -> hydrateAfterReconnect          -- calls refreshDashboard({ force: true })
//       -> refreshDashboard (store.ts)  -- fetches bootstrap
//         -> hydrateDashboardBootstrap  -- hydrates the goal_loop_status slice
//           -> hydrateGoalLoopSnapshot  -- updates goalLoopStatusData
//
// No single behavioural unit test spans this chain: hydrateDashboardBootstrap is
// a module-internal function that throws unless given a full shell + execution
// payload (it hydrates those via same-module functions that cannot be mocked),
// so exercising it would require mocking the entire bootstrap rather than the
// goal-loop slice under test. Instead this guard pins the two links that, if
// removed, silently leave the goal-loop panel stale after a reconnect while
// every other test stays green. Removing either turns this red.

function functionBody(source: string, name: string): string {
  const decl = new RegExp(`(?:async\\s+)?function\\s+${name}\\b`).exec(source)
  if (!decl) throw new Error(`function ${name} not found`)
  const braceStart = source.indexOf('{', decl.index)
  if (braceStart < 0) throw new Error(`no body for ${name}`)
  let depth = 0
  for (let i = braceStart; i < source.length; i++) {
    if (source[i] === '{') depth++
    else if (source[i] === '}') {
      depth--
      if (depth === 0) return source.slice(braceStart, i + 1)
    }
  }
  throw new Error(`unbalanced braces in ${name}`)
}

const sseStore = readFileSync(resolve(process.cwd(), 'src/sse-store.ts'), 'utf8')
const store = readFileSync(resolve(process.cwd(), 'src/store.ts'), 'utf8')

describe('goal-loop reconnect re-hydration chain (RFC-0284 §6)', () => {
  it('hydrateAfterReconnect forces a dashboard refresh', () => {
    const body = functionBody(sseStore, 'hydrateAfterReconnect')
    expect(body).toMatch(/refreshDashboard\(\s*\{\s*force:\s*true\s*\}\s*\)/)
  })

  it('hydrateDashboardBootstrap hydrates the goal_loop_status slice', () => {
    const body = functionBody(store, 'hydrateDashboardBootstrap')
    expect(body).toContain('data.goal_loop_status')
    expect(body).toContain('hydrateGoalLoopSnapshot')
  })
})
