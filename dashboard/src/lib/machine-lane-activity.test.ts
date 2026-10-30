import { execFileSync } from 'node:child_process'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { describe, expect, it } from 'vitest'
import { readMachineActivity, writeMachineActivity } from './machine-lane-activity'

describe('machine activity TOML structure', () => {
  it.each([
    '', '[machines]', 'machines = {}', '[machines.msx]',
    '[machines]\nmsx = {}', 'machines.msx = {}',
    '"machines.msx" = false',
    'notes = """\n[machines.msx]\nenabled = false\n"""',
  ])('defaults omitted flags to on: %s', source => {
    expect(readMachineActivity(source, 'msx')).toEqual({ enabled: true })
    expect(readMachineActivity(source, 'dos')).toEqual({ enabled: true })
  })

  it.each([
    '[machines.msx]\nenabled = false',
    '["machines" . \'msx\']\n"enabled" = false',
    '["mach\\u0069nes"."ms\\u0078"]\n"enabl\\u0065d" = false',
    'machines.msx.enabled = false',
    '[machines]\nmsx.enabled = false',
    'machines = {msx = {enabled = false}}',
    'machines = {msx.enabled = false}',
    '[machines]\nmsx = {enabled = false}',
  ])('reads every server-supported table form: %s', source => {
    expect(readMachineActivity(source, 'msx')).toEqual({ enabled: false })
    expect(readMachineActivity(source, 'dos')).toEqual({ enabled: true })
    const updated = writeMachineActivity(source, 'msx', true)
    expect(readMachineActivity(updated, 'msx')).toEqual({ enabled: true })
    expect(readMachineActivity(updated, 'dos')).toEqual({ enabled: true })
  })

  it.each([
    'machines = false', 'machines = []', '[[machines]]',
    '[machines]\nmsx = false', '[machines]\ndos = []', '[[machines.msx]]',
    '[machines.msx]\nenabled = "false"', '[machines.dos]\nenabled = 0',
    '[machines.msx.enabled]', '[[machines.dos.enabled]]',
    '[machines.unknown]', '[machines.msx]\nother = true',
    'machines = {dos = {other = false}}', 'machines.msx.enabled.extra = false',
    '[machines.msx]\nenabled = false\nenabled = true',
  ])('rejects malformed machines even when another machine is selected: %s', source => {
    expect(() => readMachineActivity(source, 'msx')).toThrow()
    expect(() => readMachineActivity(source, 'dos')).toThrow()
    expect(() => writeMachineActivity(source, 'msx', false)).toThrow()
  })

  it('changes only the selected flag and retains inline comments and sibling state', () => {
    const source = '# note\n[machines.msx]\nenabled = true # operator note\n[machines.dos]\nenabled = false\n'
    const updated = writeMachineActivity(source, 'msx', false)
    expect(updated).toBe(source.replace('enabled = true', 'enabled = false'))
    expect(readMachineActivity(updated, 'dos')).toEqual({ enabled: false })
  })
})

// Before the repair, reading these valid TOML documents could mutate
// Object.prototype. Each case imports the actual helper in a fresh child so a
// failing regression cannot contaminate Vitest, another test, or the parent.
describe('machine activity prototype isolation', () => {
  it.each([
    { source: '[__proto__.machines.msx]\nenabled = false', rejects: false },
    { source: '__proto__.machines.msx.enabled = false', rejects: false },
    { source: '[machines.__proto__]\nenabled = false', rejects: true },
    { source: '[machines]\n__proto__ = true', rejects: true },
    { source: 'machines = {__proto__ = {enabled = false}}', rejects: true },
    { source: '[machines.msx]\n__proto__ = true', rejects: true },
    { source: '[machines.msx.__proto__]\nenabled = false', rejects: true },
    { source: '[machines.constructor]\nenabled = false', rejects: true },
    { source: '[machines.msx]\ntoString = false', rejects: true },
  ])('does not hide or inherit keys: $source', ({ source, rejects }) => {
    const moduleUrl = pathToFileURL(resolve('src/lib/machine-lane-activity.ts')).href
    const script = `
      import { readMachineActivity, writeMachineActivity } from ${JSON.stringify(moduleUrl)};
      const before = Object.getOwnPropertyNames(Object.prototype).sort();
      const capture = fn => { try { return { value: fn() }; } catch (error) { return { error: String(error) }; } };
      const source = ${JSON.stringify(source)};
      const read = capture(() => readMachineActivity(source, 'msx'));
      const write = capture(() => readMachineActivity(writeMachineActivity(source, 'msx', false), 'msx'));
      const empty = capture(() => readMachineActivity('', 'msx'));
      const after = Object.getOwnPropertyNames(Object.prototype).sort();
      console.log(JSON.stringify({ before, after, read, write, empty }));
    `
    const result = JSON.parse(execFileSync(process.execPath,
      ['--import', 'tsx', '--input-type=module', '--eval', script], { encoding: 'utf8' }))
    expect(result.after).toEqual(result.before)
    expect(result.empty).toEqual({ value: { enabled: true } })
    if (rejects) {
      expect(result.read.error).toBeTypeOf('string')
      expect(result.write.error).toBeTypeOf('string')
    } else {
      expect(result.read).toEqual({ value: { enabled: true } })
      expect(result.write).toEqual({ value: { enabled: false } })
    }
  })
})
