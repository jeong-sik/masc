import { expect, it } from 'vitest'
import * as Y from 'yjs'
import { runArtifactDocumentCommand as run } from './artifact-document-command'

function accepted(input: unknown) {
  const result = run(input)
  if (!result.ok) throw new Error(result.code + ': ' + result.message)
  return result
}

it('refuses a genuine same-root map update without returning a committed state', () => {
  const first = accepted({ kind: 'seed', content: 'safe text' }), remote = new Y.Doc()
  try {
    Y.applyUpdate(remote, Uint8Array.from(atob(first.state!), value => value.charCodeAt(0)))
    remote.getMap('content').set('actor', 'trusted-keeper')
    const update = btoa(String.fromCharCode(...Y.encodeStateAsUpdate(remote)))
    const refused = run({ kind: 'merge', state: first.state, updates: [update] })
    expect(refused).toMatchObject({ ok: false, code: 'invalid_document' })
    expect(refused).not.toHaveProperty('state')
    expect(accepted({ kind: 'merge', state: first.state, updates: [] }).content).toBe('safe text')
  } finally { remote.destroy() }
})

it('roundtrips Korean, emoji, BOM and CRLF through the worker protocol and returns an anchored Keeper edit', () => {
  const first = accepted({ kind: 'seed', content: '\uFEFF한글 😀\r\n본문\r\n' })
  const selected = accepted({ kind: 'select', state: first.state, anchor: 8, head: 10 })
  const edited = accepted({ kind: 'edit', state: first.state, selection: selected.selection, expected: '본문', replacement: '함께 쓴 본문' })
  expect(edited.content).toBe('\uFEFF한글 😀\r\n함께 쓴 본문\r\n')
  expect(edited.range).toEqual({ anchor: 8, head: 15 })
  expect(accepted({ kind: 'resolve', state: edited.state, selection: edited.selection }).range).toEqual(edited.range)
})

it.each([
  { kind: 'unknown' },
  { kind: 'seed', content: '원고', actor: 'trusted-keeper' },
  { kind: 'merge', state: '!', updates: [] },
  { kind: 'select', state: '', anchor: -1, head: 0 },
  { kind: 'edit', state: '', selection: { anchor: [256], head: [] }, expected: '', replacement: '' },
])('refuses malformed or extra command fields without returning state: %o', input => {
  expect(run(input)).toEqual({ ok: false, code: 'invalid_request', message: 'invalid artifact document command' })
})

it('refuses malformed document bytes and noncanonical base64 without returning state', () => {
  for (const state of ['AA==', 'AB==']) {
    const result = run({ kind: 'merge', state, updates: [] })
    expect(result.ok).toBe(false)
    expect(result).not.toHaveProperty('state')
  }
})

it('returns a typed refusal for a stale Keeper range and leaves the committed state usable', () => {
  const first = accepted({ kind: 'seed', content: '원래 본문' })
  const selected = accepted({ kind: 'select', state: first.state, anchor: 0, head: 2 })
  const edited = accepted({ kind: 'edit', state: first.state, selection: selected.selection, expected: '원래', replacement: '수정' })
  const refused = run({ kind: 'edit', state: edited.state, selection: selected.selection, expected: '원래', replacement: '덮어쓰기' })
  expect(refused.ok).toBe(false)
  expect(refused).not.toHaveProperty('state')
  expect(accepted({ kind: 'merge', state: edited.state, updates: [] }).content).toBe('수정 본문')
})

it('rejects broken surrogate replacements before changing the draft', () => {
  const first = accepted({ kind: 'seed', content: '😀' })
  const selected = accepted({ kind: 'select', state: first.state, anchor: 0, head: 2 })
  expect(run({ kind: 'edit', state: first.state, selection: selected.selection, expected: '😀', replacement: '\uD800' }))
    .toMatchObject({ ok: false, code: 'invalid_document' })
  expect(accepted({ kind: 'merge', state: first.state, updates: [] }).content).toBe('😀')
})
