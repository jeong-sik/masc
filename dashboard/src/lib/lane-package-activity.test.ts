import { describe, expect, it } from 'vitest'
import { readPackageActivity, writePackageActivity } from './lane-package-activity'

describe('package activity changes preserve the declaration', () => {
  it.each(['enabled', '"enabled"', '"enabl\\u0065d"', "'enabled'"])('changes only the %s value, preserving comments and nested flags', key => {
    const source = `# header\r\n${key} = true # keep\r\nid = "pkg"\r\n[binding]\nenabled = false\r\ntext = '''\n[enabled]\nenabled = true\n'''\r\n`
    const off = writePackageActivity(source, 'pkg', false)
    expect(off).toBe(source.replace(`${key} = true # keep`, `${key} = false # keep`))
    expect(readPackageActivity(off, 'pkg')).toBe(false)
    expect(writePackageActivity(off, 'pkg', true)).toBe(source)
  })
  it('reads omitted activity as on and inserts its key at root without rewriting bindings', () => {
    const source = 'id = "pkg"\n[binding]\nenabled = true\n'
    expect(readPackageActivity(source, 'pkg')).toBe(true)
    expect(writePackageActivity(source, 'pkg', true)).toBe(source)
    expect(writePackageActivity(source, 'pkg', false)).toBe(`enabled = false\n${source}`)
  })
  it.each(['enabled = "false"', 'enabled.bad = true', '[enabled]', '[[enabled]]', 'enabled = true\nenabled = false'])('refuses malformed activity instead of inventing On: %s', invalid => {
    expect(() => writePackageActivity(`id = "pkg"\n${invalid}\n`, 'pkg', false)).toThrow()
  })
  it('does not change a reused file belonging to another installation', () => {
    expect(() => writePackageActivity('id = "replacement"\nenabled = true\n', 'pkg', false)).toThrow(/different installation/)
  })
  it('keeps special binding keys inert without converting them to a JS object', () => {
    const before = Object.getOwnPropertyDescriptors(Object.prototype)
    const source = 'id = "pkg"\n[binding.__proto__]\nenabled = false\n[binding.constructor.prototype]\nvalue = "retained"\n'
    expect(writePackageActivity(source, 'pkg', false)).toBe(`enabled = false\n${source}`)
    expect(Object.getOwnPropertyDescriptors(Object.prototype)).toEqual(before)
  })
})
