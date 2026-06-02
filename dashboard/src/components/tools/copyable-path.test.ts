// @vitest-environment happy-dom
import { describe, it, expect } from 'vitest'
import { copyablePath } from './config-resolution-panel'

describe('copyablePath (pure)', () => {
  it('returns the absolute path verbatim (unambiguous for terminal cd / Slack share)', () => {
    // Reference UIs (GitHub breadcrumb, Vercel deployment, Datadog host
    // path): the displayed form is frequently shortened (~/foo,
    // relative-to-root) but the CLIPBOARD form is always absolute.
    expect(copyablePath({ path: '/Users/dancer/me/.masc/config/personas' }))
      .toBe('/Users/dancer/me/.masc/config/personas')
  })

  it('empty path → empty string (no undefined leak into toast/clipboard)', () => {
    expect(copyablePath({ path: '' })).toBe('')
  })

  it('preserves trailing slashes — directory semantics matter to operators', () => {
    // Regression guard: a future \"cleanup\" that trims trailing slashes
    // would break operators who rely on \"/var/log/\" meaning a directory
    // for their `ls` muscle memory.
    expect(copyablePath({ path: '/tmp/cache/' })).toBe('/tmp/cache/')
  })

  it('preserves spaces and other quote-worthy characters — caller is responsible for shell escaping', () => {
    // We do NOT pre-quote the path. The operator's shell / paste target
    // owns escaping; silently quoting here would double-quote in Slack
    // and break in zsh.
    expect(copyablePath({ path: '/Users/dan cer/My Stuff/file.txt' }))
      .toBe('/Users/dan cer/My Stuff/file.txt')
  })
})
