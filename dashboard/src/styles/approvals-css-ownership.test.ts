// CSS ownership guard for the approvals surface.
//
// The shared .ap-* card/queue/action/kind styles are owned by the vendored
// design SSOT keeper-v2/surfaces.css (§APPROVALS), which main.ts loads AFTER the
// *-v2.css glob. If approvals-v2.css re-declares any of those selectors, the two
// definitions silently fight on load order (a split-brain): an editor changing
// approvals-v2.css sees no effect because surfaces.css overrides it. This test
// pins the invariant — approvals-v2.css must define ONLY selectors surfaces.css
// does not, except for a small, explicit allowlist of intentional augmentations.
//
// Non-vacuous: reverting the dedup re-introduces the shared selectors and this
// test fails; dropping a shared selector from surfaces.css fails the ownership
// assertion below (which would make the dedup an actual regression).

import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

// Read the stylesheets as text from disk. We can't `import … ?raw` them: this
// project's vitest config stubs `.css` imports to empty, and import.meta.url is
// not a file: URL under the module runner. Resolve relative to cwd, tolerating
// either the dashboard package root or the repo root, and fail loudly if absent.
function readStyle(rel: string): string {
  const candidates = [
    resolve(process.cwd(), 'src/styles', rel),
    resolve(process.cwd(), 'dashboard/src/styles', rel),
  ]
  const found = candidates.find(existsSync)
  if (!found) {
    throw new Error(`approvals-css-ownership.test: cannot locate ${rel} from cwd=${process.cwd()} (tried: ${candidates.join(', ')})`)
  }
  return readFileSync(found, 'utf8')
}

const approvalsCss = readStyle('approvals-v2.css')
const surfacesCss = readStyle('keeper-v2/surfaces.css')

// Extract the set of TOP-LEVEL rule selectors from a stylesheet. At-rule blocks
// (@media/@supports/@keyframes/@font-face) are skipped: their nested rules are a
// legitimately different cascade context, not split-brain duplication.
function topLevelSelectors(css: string): Set<string> {
  const cleaned = css
    .replace(/\/\*[\s\S]*?\*\//g, '') // strip comments
    .replace(/(['"])(?:\\.|(?!\1).)*\1/g, '""') // neutralize string literals so braces inside them can't skew depth
  const selectors = new Set<string>()
  let depth = 0
  let prelude = ''
  for (const ch of cleaned) {
    if (ch === '{') {
      if (depth === 0) {
        const head = prelude.trim()
        if (!head.startsWith('@')) {
          for (const sel of head.split(',')) {
            const norm = sel.trim().replace(/\s+/g, ' ')
            if (norm) selectors.add(norm)
          }
        }
      }
      depth += 1
      prelude = ''
    } else if (ch === '}') {
      depth = Math.max(0, depth - 1)
      prelude = ''
    } else if (depth === 0) {
      prelude += ch
    }
  }
  return selectors
}

// Selectors approvals-v2.css is allowed to share with surfaces.css because it
// augments the surfaces.css base rule with a declaration surfaces.css does not
// provide (not a full redefinition):
//   .ap-req-goal  — the goal link renders as a <button>, needs the chrome reset
//   .ap-req-quote — word wrapping for long single-token input previews
const AUGMENTATION_ALLOWLIST = new Set(['.ap-req-goal', '.ap-req-quote'])

// Representative shared selectors that MUST stay owned by surfaces.css (SSOT) and
// MUST NOT be redefined by approvals-v2.css. If surfaces.css ever drops one, the
// dedup would silently become a regression — this catches that.
const SURFACES_OWNED = [
  '.ap-card',
  '.ap-main',
  '.ap-h',
  '.ap-act',
  '.ap-queue',
  '.ap-kind',
  '.ap-title',
  '.ap-detail',
  '.ap-req',
  '.ap-actions',
  '.ap-clear',
  '.ap-sla',
]

describe('approvals CSS ownership (no surfaces.css split-brain)', () => {
  const approvals = topLevelSelectors(approvalsCss)
  const surfaces = topLevelSelectors(surfacesCss)

  it('approvals-v2.css does not redefine any surfaces.css selector (except augmentations)', () => {
    const overlap = [...approvals].filter(sel => surfaces.has(sel) && !AUGMENTATION_ALLOWLIST.has(sel))
    expect(overlap, `approvals-v2.css redefines surfaces.css-owned selectors: ${overlap.join(', ')}`).toEqual([])
  })

  it('each allowlisted augmentation is still defined in both files (no stale allowlist)', () => {
    for (const sel of AUGMENTATION_ALLOWLIST) {
      expect(approvals.has(sel), `${sel} allowlisted but not in approvals-v2.css`).toBe(true)
      expect(surfaces.has(sel), `${sel} allowlisted but not in surfaces.css`).toBe(true)
    }
  })

  it('shared card selectors remain owned by surfaces.css and are not duplicated in approvals-v2.css', () => {
    for (const sel of SURFACES_OWNED) {
      expect(surfaces.has(sel), `${sel} must remain owned by keeper-v2/surfaces.css (SSOT)`).toBe(true)
      expect(approvals.has(sel), `${sel} must not be redefined in approvals-v2.css (split-brain)`).toBe(false)
    }
  })

  it('surface-unique selectors stay in approvals-v2.css', () => {
    // These have no surfaces.css owner; they must live here.
    for (const sel of ['.ap-workspace', '.ap-detail-panel', '.ap-dossier', '.ap-detail-toggle', '.ap-act.always', '.ap-error']) {
      expect(approvals.has(sel), `${sel} is surface-unique and must stay in approvals-v2.css`).toBe(true)
      expect(surfaces.has(sel), `${sel} unexpectedly appeared in surfaces.css`).toBe(false)
    }
  })
})
