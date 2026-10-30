import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createHash } from 'node:crypto'
import { Window } from 'happy-dom'
import { buildProject, decodeProject, type ProjectRequest } from '../src/project.ts'

function request(files: Record<string, string | Buffer>): ProjectRequest {
  return { schema: 'masc.artifact_project.v1', build: { kind: 'browser_modules', entry_html: 'index.html' }, install_scripts: false,
    files: Object.entries(files).map(([path, contents]) => ({ path, content_base64: Buffer.from(contents).toString('base64') })) }
}
async function workspace() { return mkdtemp(join(tmpdir(), 'masc-project-test-')) }
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aFEkAAAAASUVORK5CYII=', 'base64')

test('rejects traversal, aliases, dependency uploads, wrong schema and noncanonical bytes before materialization', () => {
  const base = request({ 'package.json': '{}', 'index.html': '<p>한글</p>' })
  const attempts: unknown[] = [
    { ...base, schema: 'masc.artifact_project.v2' }, { ...base, additional: true },
    ...['../escape', '/escape', 'C:/escape', 'a\\b', 'a/./b', 'a//b', 'node_modules/pkg.js', '.git/config', 'nul\0byte'].map(path => ({ ...base, files: [...base.files, { path, content_base64: '' }] })),
    { ...base, files: [...base.files, base.files[0]] },
    { ...base, files: [...base.files, { path: 'bad', content_base64: 'YQ' }] },
  ]
  attempts.forEach(value => assert.throws(() => decodeProject(value)))
  assert.deepEqual(decodeProject(base), base)
})

test('installs real React/npm packages, compiles TSX and dynamic imports, embeds assets and executes the generated app', async () => {
  const value = request({
    'package.json': JSON.stringify({ name: 'artifact-fixture', private: true, dependencies: { react: '19.3.1', 'react-dom': '19.3.1', clsx: '2.1.1' } }),
    'index.html': '<!doctype html><html lang="ko"><head><title>공동 편집 앱</title><link rel="stylesheet" href="./first.css"><style>.x{color:blue;background:url(./pixel.png)}</style></head><body><div id="root" class="x" style="--hero:URL(./pixel.png);background-image:var(--hero)"></div><img src="./pixel.png"><script type="module" src="./src/main.tsx"></script></body></html>',
    'first.css': '.x{color:red}', 'pixel.png': png,
    'src/main.tsx': `import {useState} from 'react';import{createRoot}from'react-dom/client';import{flushSync}from'react-dom';import clsx from'clsx';import'./theme.css';import logo from'../pixel.png';
      function App(){const [count,setCount]=useState(0);return <button id="counter" className={clsx('button',count>0&&'changed')} onClick={()=>{flushSync(()=>setCount(count+1));import('./message.ts').then(x=>{document.title=x.label})}}><img src={logo}/>함께 편집 {count} 😀</button>}
      flushSync(()=>createRoot(document.getElementById('root')!).render(<App/>));`,
    'src/theme.css': '.button{font-weight:bold;background-image:url(../pixel.png)}',
    'src/message.ts': 'export const label: string = "클릭 완료";',
  })
  const frozen = structuredClone(value), root = await workspace(), result = await buildProject(value, root)
  assert.ok(result.output.kind === 'html' && result.build.kind === 'browser_modules')
  assert.equal(result.build.entry_html, value.build.entry_html)
  assert.deepEqual(value, frozen)
  assert.equal(result.install.mode, 'ci'); assert.equal(result.install.lock_source, 'resolved'); assert.equal(result.build.esbuild, '0.28.2')
  assert.equal(result.output.artifact.sha256, createHash('sha256').update(result.output.artifact.content).digest('hex'))
  assert.equal((await readFile(join(result.run_directory, 'result.json'), 'utf8')), JSON.stringify(result) + '\n')
  const window = new Window({ settings: { disableCSSFileLoading: true, disableJavaScriptFileLoading: true } })
  try {
    window.document.write(result.output.artifact.content)
    const styles = [...window.document.querySelectorAll('style')].map(node => node.textContent ?? '')
    assert.ok(styles[0].includes('red')); assert.ok(styles[1].includes('blue'))
    assert.ok(styles[1].includes('data:image/png;base64,'))
    assert.ok(window.document.getElementById('root')!.getAttribute('style')!.includes('data:image/png;base64,'))
    for (const script of window.document.querySelectorAll('script')) window.eval(script.textContent ?? '')
    assert.equal(window.document.getElementById('counter')?.textContent, '함께 편집 0 😀')
    window.document.getElementById('counter')!.dispatchEvent(new window.MouseEvent('click', { bubbles: true }))
    assert.equal(window.document.getElementById('counter')?.textContent, '함께 편집 1 😀')
    await window.happyDOM.waitUntilComplete()
    assert.equal(window.document.title, '클릭 완료')
    assert.equal(window.document.getElementById('counter')!.className, 'button changed')
    assert.ok([...window.document.querySelectorAll('img')].every(image => image.src.startsWith('data:image/png;base64,')))
  } finally { await window.happyDOM.close() }
  // The worker's returned lock bytes really drive the next install. No snapshot
  // or mocked package manager substitutes for this second npm ci run.
  const locked = structuredClone(value)
  locked.files.push({ path: 'package-lock.json', content_base64: Buffer.from(result.install.lock_content).toString('base64') })
  const again = await buildProject(locked, root)
  assert.ok(again.output.kind === 'html')
  assert.equal(again.install.mode, 'ci'); assert.equal(again.install.lock_source, 'supplied'); assert.equal(again.install.lock_sha256, result.install.lock_sha256)
  assert.equal(again.output.artifact.content, result.output.artifact.content)
})

test('install hooks are explicit, do not inherit host secrets, and input bytes stay unchanged', async () => {
  const value = request({
    'package.json': JSON.stringify({ name: 'install-fixture', private: true, scripts: { postinstall: 'node hook.cjs' } }),
    'hook.cjs': 'require("fs").writeFileSync("marker.json",JSON.stringify({secret:process.env.MASC_PROJECT_TEST_SECRET??null,home:process.env.HOME}))',
    'index.html': '<p>원본 문서</p>',
  })
  const previous = process.env.MASC_PROJECT_TEST_SECRET
  process.env.MASC_PROJECT_TEST_SECRET = 'fixture-secret-never-forward'
  try {
    const root = await workspace(), skipped = await buildProject(value, root)
    await assert.rejects(readFile(join(skipped.run_directory, 'source', 'marker.json')))
    const allowed = await buildProject({ ...value, install_scripts: true }, root)
    const marker = JSON.parse(await readFile(join(allowed.run_directory, 'source', 'marker.json'), 'utf8'))
    assert.equal(marker.secret, null)
    assert.equal(marker.home, join(allowed.run_directory, 'npm-home'))
    assert.equal((await readFile(join(allowed.run_directory, 'source', 'index.html'), 'utf8')), '<p>원본 문서</p>')
  } finally {
    if (previous === undefined) delete process.env.MASC_PROJECT_TEST_SECRET
    else process.env.MASC_PROJECT_TEST_SECRET = previous
  }
})

test('rejects imports outside the project and unresolved local resources, retaining failed run evidence', async () => {
  const root = await workspace(), outside = join(root, 'outside.js')
  await writeFile(outside, 'globalThis.secret="outside";')
  const value = request({ 'package.json': '{"name":"boundaries","private":true}', 'index.html': '<script type="module" src="main.js"></script>', 'main.js': `import ${JSON.stringify(outside)}` })
  await assert.rejects(buildProject(value, root), error => {
    assert.ok(error instanceof Error && 'run_directory' in error && typeof error.run_directory === 'string')
    assert.match(error.message, /outside the installed project/)
    return true
  })
  await assert.rejects(buildProject(request({ 'package.json': '{}', 'index.html': '<style>.x{background:url(missing.png)}</style>' }), root), /Could not resolve/)
})


test('literal fragment/query characters in entry directories resolve local assets correctly', async () => {
  const value = request({ 'package.json': '{}', 'src/view#1?part/index.html': '<img src="logo.png">', 'src/view#1?part/logo.png': png })
  value.build.entry_html = 'src/view#1?part/index.html'
  const result = await buildProject(value, await workspace())
  assert.ok(result.output.kind === 'html')
  assert.ok(result.output.artifact.content.includes('data:image/png;base64,'))
})

test('preserves distinct SVG fragment identifiers across HTML attributes and inline CSS URLs', async () => {
  const svg = '<svg xmlns="http://www.w3.org/2000/svg"><view id="icon-a" viewBox="0 0 10 10"/><view id="icon-b" viewBox="10 0 10 10"/></svg>'
  const value = request({
    'package.json': '{}',
    'index.html': '<img id="a" src="sprite.svg#icon-a"><img id="b" src="sprite.svg#icon-b"><div id="bg" style="background-image:url(sprite.svg#icon-b)"></div>',
    'sprite.svg': svg,
  })
  const result = await buildProject(value, await workspace())
  const encoded = `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`
  assert.ok(result.output.kind === 'html')
  assert.ok(result.output.artifact.content.includes(`id="a" src="${encoded}#icon-a"`))
  assert.ok(result.output.artifact.content.includes(`id="b" src="${encoded}#icon-b"`))
  assert.ok(result.output.artifact.content.includes(`${encoded}#icon-b`))
})


test('refuses multiple HTML module entries instead of changing their timing or external import order', async () => {
  await assert.rejects(buildProject(request({ 'package.json': '{}', 'index.html': '<script type="module">globalThis.first=true</script><script type="module" src="https://cdn.example/second.js"></script>' }), await workspace()), /Multiple HTML module entries/)
})
