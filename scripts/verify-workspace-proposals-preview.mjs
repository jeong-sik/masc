// Run with the dashboard's installed Playwright, a downloaded CI preview,
// and a live backend with write methods/WebSockets blocked. No local compilation.
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { resolve, relative, extname, sep } from 'node:path'
import assert from 'node:assert/strict'
const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [previewArgument, expectedHead, baseUrl, outputArgument] = process.argv.slice(2)
if (!previewArgument || !expectedHead || !baseUrl || !outputArgument) {
  throw new Error('Usage: node scripts/verify-workspace-proposals-preview.mjs PREVIEW_DIR PR_HEAD BACKEND_URL EVIDENCE_DIR')
}
const fixturePath = new URL('../docs/evidence/2026-09-10-workspace-memory-curator/qwen38-27b/proposal.json', import.meta.url)
const fixtureBytes = await readFile(fixturePath)
const actualProposal = JSON.parse(fixtureBytes)
const firstId = createHash('sha256').update(fixtureBytes).digest('hex')
const secondId = 'b'.repeat(64)
const secondProposal = structuredClone(actualProposal)
secondProposal.proposal.shared_claims[0].claim = 'Synthetic second proposal for selection preservation.'
const item = (id, proposal) => ({ id, proposal, semantic_verification: 'not_performed' })
const first = item(firstId, actualProposal)
const second = item(secondId, secondProposal)
let proposals = [first, second]
let fixtureStatus = 200
const root = resolve(previewArgument)
const output = resolve(outputArgument)
const manifest = JSON.parse(await readFile(resolve(root, 'preview-provenance.json'), 'utf8'))
assert.equal(manifest.pr_head_commit, expectedHead)
for (const [name, hash] of Object.entries(manifest.files)) {
  const file = resolve(root, name)
  assert.ok(!relative(root, file).startsWith(`..${sep}`) && file.startsWith(root + sep))
  assert.equal(createHash('sha256').update(await readFile(file)).digest('hex'), hash, name)
}
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
  '.json': 'application/json', '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.png': 'image/png' }
await mkdir(output, { recursive: true })
const browser = await chromium.launch({ headless: true })
const mutations = []
const blockedWebSockets = []
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, serviceWorkers: 'block' })
  await page.routeWebSocket('**/*', socket => {
    blockedWebSockets.push(socket.url())
    socket.close()
  })
  const pageErrors = []
  page.on('pageerror', error => pageErrors.push(error.message))
  await page.route('**/*', async route => {
    const request = route.request()
    if (!['GET', 'HEAD'].includes(request.method())) {
      mutations.push({ method: request.method(), path: new URL(request.url()).pathname })
      return route.abort()
    }
    const url = new URL(request.url())
    if (url.origin === new URL(baseUrl).origin && url.pathname === '/api/v1/dashboard/workspace-memory-proposals') {
      return route.fulfill({ status: fixtureStatus, json: fixtureStatus === 200
        ? { proposals, semantic_verification: 'not_performed' } : { error: 'fixture: proposal store unavailable' } })
    }
    if (url.origin === new URL(baseUrl).origin && url.pathname.startsWith('/dashboard/')) {
      const name = decodeURIComponent(url.pathname.slice('/dashboard/'.length)) || 'index.html'
      assert.ok(Object.hasOwn(manifest.files, name), `Unmanifested asset: ${name}`)
      return route.fulfill({ body: await readFile(resolve(root, name)),
        contentType: mime[extname(name)] ?? 'application/octet-stream' })
    }
    return route.continue()
  })
  await page.goto(new URL('/dashboard/#lab?section=keeper-memory-health', baseUrl).href)
  const panel = page.locator('[data-workspace-memory-proposals]')
  const originalClaim = actualProposal.proposal.shared_claims[0].claim
  await panel.getByText(originalClaim, { exact: true }).waitFor()
  assert.equal(await panel.getByText(actualProposal.proposal.conflicts[0].description, { exact: true }).count(), 1)
  await panel.getByText('모델이 작성한 공간 기억 제안입니다. 내용의 사실 여부는 별도로 검증하지 않았습니다.', { exact: true }).waitFor()
  for (const gap of actualProposal.gaps) {
    await panel.getByText(`${gap.keeper_id} · 파일 출처 기억: 저장된 기억 없음`, { exact: true }).waitFor()
  }
  await panel.getByRole('button', { name: 's2 · reviewer · 일반 기억', exact: true }).click()
  const source = panel.getByRole('region', { name: '선택한 출처' }).locator('pre')
  const sourceValue = JSON.parse(await source.textContent())
  assert.deepEqual(sourceValue.source, actualProposal.sources.find(row => row.source_id === 's2'))
  assert.deepEqual(sourceValue.snapshot, actualProposal.snapshots.find(row => row.snapshot_id === sourceValue.source.snapshot_id))
  await source.focus()
  assert.equal(await source.evaluate(element => element === document.activeElement), true)
  await panel.scrollIntoViewIfNeeded()
  await page.screenshot({ path: resolve(output, 'desktop.png') })
  await panel.screenshot({ path: resolve(output, 'proposal-panel.png') })
  await page.setViewportSize({ width: 390, height: 844 })
  await panel.scrollIntoViewIfNeeded()
  const mobileOverflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth)
  assert.equal(mobileOverflow, false)
  await page.screenshot({ path: resolve(output, 'mobile.png') })
  await panel.getByLabel('제안 선택').selectOption(secondId)
  await panel.getByText(secondProposal.proposal.shared_claims[0].claim, { exact: true }).waitFor()
  proposals = [second, first]
  await panel.getByRole('button', { name: '제안 새로 읽기', exact: true }).click()
  await panel.getByText(secondProposal.proposal.shared_claims[0].claim, { exact: true }).waitFor()
  assert.equal(await panel.getByLabel('제안 선택').inputValue(), secondId)
  fixtureStatus = 503
  await panel.getByRole('button', { name: '제안 새로 읽기', exact: true }).click()
  await panel.getByRole('alert').waitFor()
  assert.equal(await panel.getByText('저장된 공간 기억 제안이 없습니다.', { exact: true }).count(), 0)
  await page.screenshot({ path: resolve(output, 'read-error.png') })
  fixtureStatus = 200
  proposals = []
  await panel.getByRole('button', { name: '제안 새로 읽기', exact: true }).click()
  await panel.getByText('저장된 공간 기억 제안이 없습니다.', { exact: true }).waitFor()
  assert.equal(await panel.getByRole('alert').count(), 0)
  proposals = [first]
  await panel.getByRole('button', { name: '제안 새로 읽기', exact: true }).click()
  await panel.getByText(originalClaim, { exact: true }).waitFor()
  assert.equal(await panel.getByLabel('제안 선택').inputValue(), firstId)
  const receipt = { observed_at: new Date().toISOString(), manifest,
    saved_model_proposal: { path: 'docs/evidence/2026-09-10-workspace-memory-curator/qwen38-27b/proposal.json', sha256: firstId },
    synthetic_selection_proposal: secondId,
    checks: ['claims', 'conflicts', 'exact_source_and_snapshot', 'gaps', 'keyboard_source_focus', 'selection_refresh', 'failure_retry', 'empty_store', 'removed_selection_fallback'],
    mobile_overflow: mobileOverflow, page_errors: pageErrors,
    backend: new URL(baseUrl).origin, blocked_mutations: mutations, blocked_websockets: blockedWebSockets,
    deployment: false, scope: 'CI-built Lab proposal panel with saved local-model proposal and synthetic selection/error responses over live backend' }
  await writeFile(resolve(output, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n')
  console.log(JSON.stringify({ saved_model_proposal_sha256: firstId, evidence: output, page_errors: pageErrors }))
} finally { await browser.close() }
