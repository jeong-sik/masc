// Exercise a real isolated MASC HTTP service and its production dashboard.
// No fixture HTTP responses, model calls, credentials in URLs, or live installs.
import assert from 'node:assert/strict'
import { createRequire } from 'node:module'
import { createHash } from 'node:crypto'
import { readFile, mkdir, writeFile } from 'node:fs/promises'
import { resolve, join } from 'node:path'

const require = createRequire(new URL('../dashboard/package.json', import.meta.url))
const { chromium } = require('playwright')
const [baseUrl, expectedCommit, expectedBase, outputDirectory, tokenFile, mode = 'create'] = process.argv.slice(2)
assert.ok(baseUrl && expectedCommit && expectedBase && outputDirectory && tokenFile,
  'Usage: BASE_URL EXPECTED_BINARY_COMMIT ISOLATED_BASE OUTPUT_DIR TOKEN_FILE [resume]')
const output = resolve(outputDirectory)
if (mode === 'create') await mkdir(output, { recursive: false })
else assert.equal(mode, 'resume')
const token = (await readFile(tokenFile, 'utf8')).trim()
assert.ok(token)
const digest = text => createHash('sha256').update(text).digest('hex')
const notes = []
const evidence = { scope: 'real isolated HTTP service and browser; no semantic model or production deployment claim',
  binaryCommit: expectedCommit, checkedAt: new Date().toISOString(), mode, checks: notes }

async function http(path, value, expectedStatus = 200, authenticated = true) {
  const response = await fetch(new URL(path, baseUrl), {
    method: value === undefined ? 'GET' : 'POST', redirect: 'error',
    headers: { 'Content-Type': 'application/json', ...(authenticated ? { Authorization: `Bearer ${token}` } : {}) },
    body: value === undefined ? undefined : JSON.stringify(value), signal: AbortSignal.timeout(30_000),
  })
  assert.equal(response.status, expectedStatus, `${path}: expected HTTP ${expectedStatus}, got ${response.status}`)
  const json = await response.json()
  assert.ok(!JSON.stringify(json).includes(token), 'credential echoed in response')
  return json
}

const htmlSource = `<!doctype html><html lang="ko"><meta charset="utf-8">
<style>body{font:18px system-ui;padding:32px;color:#19334b;background:#f4f7fb}button{font:inherit;padding:12px 24px;border:0;border-radius:12px;background:#264b79;color:white}.bar{height:24px;background:#5380aa;border-radius:5px;margin:12px 0}</style>
<h1>보고서에서 직접 확인하는 실험</h1><p>버튼을 누르면 결과가 바뀝니다.</p>
<button id="counter">확인 0회</button><div class="bar" id="bar" style="width:80px"></div>
<p id="boundary"></p><script>
let count=0;document.getElementById('counter').onclick=()=>{count++;document.getElementById('counter').textContent='확인 '+count+'회';document.getElementById('bar').style.width=(80+count*40)+'px'};
try{void parent.document.body;document.body.dataset.parentAccess='allowed'}catch{document.body.dataset.parentAccess='blocked'}
try{void localStorage.length;document.body.dataset.storageAccess='allowed'}catch{document.body.dataset.storageAccess='blocked'}
document.addEventListener('securitypolicyviolation',event=>{if(event.effectiveDirective==='connect-src'&&new URL(event.blockedURI).origin==='https://example.invalid')document.body.dataset.connectPolicy='blocked'});
fetch('https://example.invalid/report-probe').then(()=>document.body.dataset.fetch='allowed',()=>document.body.dataset.fetch='blocked');
document.getElementById('boundary').textContent='대시보드 접근: '+document.body.dataset.parentAccess;
</script></html>`

let browser
try {
  const health = await http('/health?full=1')
  assert.equal(health.build.binary_commit, expectedCommit)
  assert.equal(health.dashboard_surface.status, 'ok', 'dashboard bundle must match the actual server source')
  evidence.dashboardStatus = health.dashboard_surface.status
  assert.equal(resolve(health.paths.effective_base_path), resolve(expectedBase))
  assert.notEqual(resolve(expectedBase), resolve(process.cwd()), 'proof must use an isolated runtime workspace')
  assert.ok(Number.isSafeInteger(health.process_memory.pid) && health.process_memory.pid > 0)
  evidence.servicePid = health.process_memory.pid
  if (mode === 'resume') {
    const created = JSON.parse(await readFile(join(output, 'create-receipt.json'), 'utf8'))
    assert.equal(created.status, 'passed', 'create proof must pass before restart verification')
    assert.ok(Number.isSafeInteger(created.servicePid) && created.servicePid > 0, 'create proof must identify its service process')
    assert.notEqual(evidence.servicePid, created.servicePid, 'stop and restart the isolated service before resume')
    notes.push('service PID changed since successful create proof')
  }
  notes.push('actual binary commit, matched dashboard source and isolated workspace agree')
  let records
  if (mode === 'create') {
    const catalog = await http('/api/v1/published-artifacts')
    assert.deepEqual(catalog, { artifacts: [], diagnostics: [] }, 'use a fresh isolated report catalog')
    const privateResponse = await fetch(new URL('/api/v1/published-artifacts', baseUrl), { redirect: 'error' })
    assert.ok([401, 403].includes(privateResponse.status), 'catalog requires an authenticated operator')
    const markdown = await readFile(new URL('../docs/design/report-artifacts.md', import.meta.url), 'utf8')
    const published = await http('/api/v1/published-artifacts', {
      title: 'MASC 아티팩트 설계', summary: '보고서 저장부터 대시보드에서 다시 읽기까지의 설계', format: 'markdown', content: markdown,
    }, 201)
    const revisedBody = markdown + '\n\n## 브라우저 검증\n\n| 항목 | 결과 |\n|---|---|\n| 한글과 😀 | 원본 보존 |\n'
    const revised = await http('/api/v1/published-artifacts', {
      id: published.artifact.id, expected_revision: 1, title: 'MASC 아티팩트 설계',
      summary: '버전 이력과 실제 화면 검증을 포함한 설계', format: 'markdown', content: revisedBody,
    }, 201)
    assert.equal(revised.artifact.revision, 2)
    const conflict = await http('/api/v1/published-artifacts', {
      id: published.artifact.id, expected_revision: 1, title: 'stale write', summary: 'must not replace the report', format: 'markdown', content: 'stale',
    }, 409)
    assert.equal(conflict.current_revision, 2)
    const html = await http('/api/v1/published-artifacts', {
      title: '실행 가능한 보고서', summary: 'HTML 버튼과 차트를 실제로 조작하는 결과물', format: 'html', content: htmlSource,
    }, 201)
    records = { markdown: { id: published.artifact.id, firstSha256: digest(markdown), latestSha256: digest(revisedBody) },
      html: { id: html.artifact.id, sha256: digest(htmlSource) } }
    await writeFile(join(output, 'documents.json'), JSON.stringify(records, null, 2) + '\n')
    notes.push('create, revise, stale update conflict and HTML publication through actual HTTP')
  } else records = JSON.parse(await readFile(join(output, 'documents.json'), 'utf8'))

  const latest = await http(`/api/v1/published-artifacts/${records.markdown.id}`)
  const first = await http(`/api/v1/published-artifacts/${records.markdown.id}?revision=1`)
  const html = await http(`/api/v1/published-artifacts/${records.html.id}`)
  assert.equal(digest(first.content), records.markdown.firstSha256)
  assert.equal(digest(latest.content), records.markdown.latestSha256)
  assert.equal(digest(html.content), records.html.sha256)
  assert.equal(latest.artifact.revision, 2)
  assert.deepEqual(latest.revisions.map(r => r.revision), [2, 1])
  const listed = await http('/api/v1/published-artifacts')
  assert.equal(listed.artifacts.length, 2)
  assert.deepEqual(listed.diagnostics, [])
  notes.push('exact content digests, immutable old revision, newest metadata and list agree')

  browser = await chromium.launch({ headless: true })
  const context = await browser.newContext({ viewport: { width: 1440, height: 1050 }, acceptDownloads: true })
  await context.addInitScript(({ value, origin }) => {
    if (window !== window.top || location.origin !== origin) return
    sessionStorage.setItem('masc_bearer_token', value)
    sessionStorage.setItem('masc_bearer_token_meta', JSON.stringify({ source: 'manual' }))
  }, { value: token, origin: new URL(baseUrl).origin })
  const page = await context.newPage()
  const errors = []
  page.on('pageerror', error => errors.push(error.message.replaceAll(token, '[WITHHELD]')))
  const libraryUrl = new URL('/dashboard/#/workspace?section=artifacts', baseUrl).href
  await page.goto(libraryUrl)
  const library = page.getByRole('region', { name: '아티팩트 보관함' })
  await library.waitFor()
  await page.getByRole('link', { name: 'Artifacts', exact: true }).waitFor()
  await library.getByRole('button', { name: /MASC 아티팩트 설계/ }).click()
  const article = page.getByRole('article', { name: '아티팩트 본문' })
  await article.getByRole('heading', { name: 'MASC 아티팩트 설계', exact: true }).waitFor()
  await article.locator('table').waitFor()
  await page.screenshot({ path: join(output, `${mode}-desktop-markdown.png`), fullPage: true })
  await article.getByRole('button', { name: '원본', exact: true }).click()
  assert.equal(await article.getByLabel('문서 원본').textContent(), latest.content)
  await article.getByLabel('문서 버전').selectOption('1')
  await article.locator('span').filter({ hasText: 'markdown · v1' }).waitFor()
  await article.getByRole('button', { name: '원본', exact: true }).click()
  assert.equal(await article.getByLabel('문서 원본').textContent(), first.content)
  const downloadPromise = page.waitForEvent('download')
  await article.getByRole('button', { name: '원본 다운로드' }).click()
  const download = await downloadPromise
  const downloaded = await readFile(await download.path())
  assert.equal(digest(downloaded), records.markdown.firstSha256)
  await page.reload()
  await article.getByLabel('문서 버전').waitFor()
  assert.equal(await article.getByLabel('문서 버전').inputValue(), '1')
  notes.push('actual dashboard selection, GFM table rendering, source bytes, old version download and URL reload')

  await page.keyboard.press('Escape')
  await page.getByRole('dialog').waitFor({ state: 'detached' })
  await library.getByRole('searchbox').fill('실행 가능한')
  await library.getByRole('button', { name: /실행 가능한 보고서/ }).click()
  const frame = page.frameLocator('iframe[title="실행 가능한 보고서"]')
  await frame.getByRole('button', { name: '확인 0회' }).click()
  await frame.getByRole('button', { name: '확인 1회' }).waitFor()
  await frame.locator('body[data-fetch="blocked"]').waitFor()
  await frame.locator('body[data-connect-policy="blocked"]').waitFor()
  assert.equal(await frame.locator('body').getAttribute('data-parent-access'), 'blocked')
  assert.equal(await frame.locator('body').getAttribute('data-storage-access'), 'blocked')
  await page.screenshot({ path: join(output, `${mode}-desktop-html.png`), fullPage: true })
  await page.setViewportSize({ width: 390, height: 844 })
  await frame.getByRole('button', { name: '확인 1회' }).scrollIntoViewIfNeeded()
  await frame.getByRole('button', { name: '확인 1회' }).click()
  await frame.getByRole('button', { name: '확인 2회' }).waitFor()
  await page.screenshot({ path: join(output, `${mode}-mobile-html.png`), fullPage: true })
  await article.getByRole('button', { name: '목록으로' }).click()
  await page.getByRole('dialog').waitFor({ state: 'detached' })
  assert.equal(await library.getByRole('searchbox').inputValue(), '실행 가능한')
  notes.push('desktop/mobile HTML counter interaction and denied parent document/storage/fetch; screenshots retained')
  notes.push('Escape and Back return from the reader to the preserved catalog search')
  assert.deepEqual(errors, [], 'unexpected browser script errors')
  evidence.documents = records
  evidence.status = 'passed'
} catch (error) {
  evidence.status = 'failed'
  evidence.error = String(error).replaceAll(token, '[WITHHELD]')
  process.exitCode = 1
} finally {
  await browser?.close()
  await writeFile(join(output, `${mode}-receipt.json`), JSON.stringify(evidence, null, 2) + '\n')
  process.stdout.write(JSON.stringify({ status: evidence.status, checks: notes.length, receipt: join(output, `${mode}-receipt.json`) }) + '\n')
}
