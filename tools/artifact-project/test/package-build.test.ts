import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { createHash } from 'node:crypto'
import { buildProject, decodeProject, ProjectError, type ProjectRequest } from '../src/project.ts'
import { pixel, viteProject } from './package-fixture.ts'
import { runTrustedSite } from './site-browser.ts'
const work = () => mkdtemp(join(tmpdir(), 'masc-package-build-test-'))
function simple(script: string): ProjectRequest {
  const files = { 'package.json': JSON.stringify({ name: 'package-script-fixture', private: true, scripts: { build: 'node build.cjs' } }), 'build.cjs': script }
  return { schema: 'masc.artifact_project.v1', build: { kind: 'package_script', script: 'build', output_directory: 'dist', entry_html: 'index.html' }, install_scripts: false,
    files: Object.entries(files).map(([path, contents]) => ({ path, content_base64: Buffer.from(contents).toString('base64') })) }
}

test('runs actual Vite config/plugins/lifecycle and preserves every split module, page and asset byte', { timeout: 60000 }, async () => {
  const request = viteProject(), original = structuredClone(request), result = await buildProject(request, await work())
  assert.deepEqual(request, original)
  assert.equal(result.build.kind, 'package_script'); assert.ok(result.output.kind === 'site')
  const site = result.output
  assert.ok(site.files.some(file => file.path === 'nested/index.html'))
  assert.ok(site.files.some(file => file.path === 'logo.svg'))
  assert.ok(site.files.some(file => file.path.startsWith('assets/') && file.path.endsWith('.png') && Buffer.from(file.content_base64, 'base64').equals(pixel)))
  for (const file of site.files) {
    const actual = await readFile(join(result.run_directory, 'source', 'dist', file.path))
    assert.deepEqual(actual, Buffer.from(file.content_base64, 'base64'))
    assert.equal(file.bytes, actual.length); assert.equal(file.sha256, createHash('sha256').update(actual).digest('hex'))
  }
  const manifest = { entry_html: site.entry_html, files: site.files.map(({ path, bytes, sha256 }) => ({ path, bytes, sha256 })) }
  assert.equal(site.sha256, createHash('sha256').update(JSON.stringify(manifest)).digest('hex'))
  assert.equal(Buffer.from(site.files.find(file => file.path === 'lifecycle.txt')!.content_base64, 'base64').toString(), 'prebuild reached')
  const runtime = await runTrustedSite(site)
  assert.equal(runtime.after, '함께 만든 앱 1 분할 모듈 실행 😀')
})

test('collects arbitrary static bytes without flattening multiple module entry scripts', async () => {
  const value = simple(`const fs=require('fs');fs.mkdirSync('dist');fs.writeFileSync('dist/index.html','<script type="module" src="a.js"></script><script type="module" src="b.js"></script>');fs.writeFileSync('dist/a.js','globalThis.a=1');fs.writeFileSync('dist/b.js','globalThis.b=2');fs.writeFileSync('dist/binary.bin',Buffer.from([0,255,42]));`)
  const result = await buildProject(value, await work()); assert.ok(result.output.kind === 'site')
  assert.equal(result.output.files.length, 4)
  assert.deepEqual(Buffer.from(result.output.files.find(file => file.path === 'binary.bin')!.content_base64, 'base64'), Buffer.from([0,255,42]))
  assert.equal(Buffer.from(result.output.files.find(file => file.path === 'index.html')!.content_base64, 'base64').toString(), '<script type="module" src="a.js"></script><script type="module" src="b.js"></script>')
})

test('rejects missing scripts before install hooks and records a failed build without a successful result', async () => {
  const root = await work(), missing = simple('')
  missing.build = { kind: 'package_script', script: 'not-present', output_directory: 'dist', entry_html: 'index.html' }
  missing.install_scripts = true
  const packageFile = missing.files.find(file => file.path === 'package.json')!
  const pkg = JSON.parse(Buffer.from(packageFile.content_base64, 'base64').toString())
  pkg.scripts.postinstall = 'node hook.cjs'
  packageFile.content_base64 = Buffer.from(JSON.stringify(pkg)).toString('base64')
  missing.files.push({ path: 'hook.cjs', content_base64: Buffer.from('require("fs").writeFileSync("unexpected-install","hook ran")').toString('base64') })
  let failedRun = ''
  await assert.rejects(buildProject(missing, root), error => {
    assert.ok(error instanceof ProjectError && error.stage === 'input' && error.run_directory)
    failedRun = error.run_directory
    return true
  })
  await assert.rejects(readFile(join(failedRun, 'source', 'unexpected-install')))
  await assert.rejects(buildProject(simple('process.exit(7)'), root), asyncError)
  function asyncError(error: unknown) { assert.ok(error instanceof ProjectError && error.stage === 'build' && error.run_directory); return true }
})

test('refuses symlink output graphs and invalid output selections', async () => {
  await assert.rejects(buildProject(simple(`const fs=require('fs');fs.mkdirSync('dist');fs.writeFileSync('dist/index.html','<p>valid</p>');fs.symlinkSync('../build.cjs','dist/linked.js');`), await work()), /symbolic link/)
  const value = simple('')
  for (const output_directory of ['../escape', '/outside', '.', 'a/../b']) assert.throws(() => decodeProject({ ...value, build: { ...value.build, output_directory } }))
})


test('keeps the installation lock when install/build hooks replace it later', async () => {
  const value = simple(`const fs=require('fs');fs.mkdirSync('dist');fs.writeFileSync('dist/index.html','<p>built</p>');fs.writeFileSync('package-lock.json','{"changed":"during-build"}');`)
  value.install_scripts = true
  const pkg = JSON.parse(Buffer.from(value.files[0].content_base64, 'base64').toString())
  pkg.scripts.postinstall = 'node hook.cjs'
  value.files[0].content_base64 = Buffer.from(JSON.stringify(pkg)).toString('base64')
  value.files.push({ path: 'hook.cjs', content_base64: Buffer.from('require("fs").writeFileSync("package-lock.json",JSON.stringify({changed:"during-install-hook"}))').toString('base64') })
  const result = await buildProject(value, await work())
  assert.equal(result.install.lock_source, 'resolved')
  const installed = JSON.parse(result.install.lock_content)
  assert.equal(installed.lockfileVersion, 3)
  assert.equal(installed.name, 'package-script-fixture')
  assert.equal(JSON.parse(await readFile(join(result.run_directory, 'source', 'package-lock.json'), 'utf8')).changed, 'during-build')
})

test('retains the run and failure receipt when final result recording fails', async () => {
  const value = simple(`const fs=require('fs');fs.mkdirSync('dist');fs.writeFileSync('dist/index.html','<p>built</p>');fs.writeFileSync('../result.json','occupied');`)
  let failedRun = ''
  await assert.rejects(buildProject(value, await work()), error => {
    assert.ok(error instanceof ProjectError && error.stage === 'build' && error.run_directory)
    failedRun = error.run_directory
    assert.match(error.message, /EEXIST/)
    return true
  })
  const failure = JSON.parse(await readFile(join(failedRun, 'failure.json'), 'utf8'))
  assert.equal(failure.stage, 'build'); assert.match(failure.message, /EEXIST/)
})


test('keeps the known run identity even when the failure record cannot be written', async () => {
  const value = simple(`const fs=require('fs');fs.mkdirSync('dist');fs.writeFileSync('dist/index.html','<p>built</p>');fs.writeFileSync('../result.json','occupied');fs.mkdirSync('../failure.json');`)
  await assert.rejects(buildProject(value, await work()), error => {
    assert.ok(error instanceof ProjectError && error.run_directory)
    assert.match(error.message, /failed to store failure record/)
    return true
  })
})
