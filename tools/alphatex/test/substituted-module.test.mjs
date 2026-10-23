import { test } from 'node:test'
import assert from 'node:assert/strict'
import { loadSubstituted } from './helpers/substituted-module.mjs'

const fixture = name => new URL(`./fixtures/substituted/${name}.mjs`, import.meta.url)

test('an unsubstituted relative binding is the real export and a substituted one is the fake', async () => {
  const { read } = await loadSubstituted(fixture('view'), { renamed: 'fake', join: (...parts) => parts.join('+') })
  assert.deepEqual(read(), { real: 'real export', renamed: 'fake', joined: 'a+b' })
})

test('a builtin binding must be substituted and is named when it is not', async () => {
  await assert.rejects(loadSubstituted(fixture('view'), {}), /Substitute join from node:path/)
})

test('an import form other than one-line named imports is refused', async () => {
  await assert.rejects(loadSubstituted(fixture('default-import'), {}), /Unsupported import form/)
})

test('a binding the real module does not export is named', async () => {
  await assert.rejects(loadSubstituted(fixture('missing-export'), {}), /has no export absent/)
})

test('a substitute the view does not import is refused, and a name it uses without importing is a global', async () => {
  await assert.rejects(loadSubstituted(fixture('view'), { renamed: 'fake', join: () => '', wirte: () => '' }),
    /does not import wirte/)
  const { read } = await loadSubstituted(fixture('global-use'), {}, { globals: { process: { title: 'shadowed' } } })
  assert.equal(read(), 'shadowed')
})

test('an indented import and a name imported twice are refused, as the real link would refuse them', async () => {
  await assert.rejects(loadSubstituted(fixture('indented-import'), {}), /Unsupported import form/)
  await assert.rejects(loadSubstituted(fixture('duplicate-import'), {}), /imports real twice/)
})

test('a substituted name must still exist in its module', async () => {
  await assert.rejects(loadSubstituted(fixture('missing-export'), { absent: 'fake' }), /has no export absent/)
})
