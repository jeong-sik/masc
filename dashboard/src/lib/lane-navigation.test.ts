import { describe, expect, it } from 'vitest'
import { hashForRoute, initRouter, replaceRoute, route } from '../router'
import { declarationIdentity, laneTargetParams, parseLaneTarget, runtimeTargetRange, type RuntimeLaneTarget } from './lane-navigation'

describe('Lane destinations at the URL and TOML boundaries', () => {
  it('round-trips a declaration path with URL delimiters and Unicode through the real router', () => {
    const target = { kind: 'declaration' as const, workspace: '/workspace A', path: '/workspace A/한글 #?% &.toml', installation: 'pkg' }
    window.location.hash = hashForRoute('monitoring', laneTargetParams(target)); initRouter()
    expect(route.value.params.section).toBe('lane-addons')
    expect(parseLaneTarget(route.value.params.lane_target)).toEqual({ kind: 'target', target })
    replaceRoute('overview', route.value.params)
    expect(route.value.params.lane_target).toBeUndefined()
  })
  it.each([
    { kind: 'exact', workspace: '/workspace', lane: 'invented' },
    { kind: 'run_history', workspace: '/workspace', lane: 'invented' },
    { kind: 'run_history', workspace: '/workspace', lane: 'workspace_curator_exact', run_id: 'invented' },
    { kind: 'instance', workspace: '/workspace', instance: 'worker' },
    { kind: 'machine', workspace: '/workspace', machine: 'dos', extra: true },
    { kind: 'declaration', workspace: '/workspace', path: 'p' },
  ])('refuses incomplete or unknown selection instead of choosing a fallback: %j', target => {
    expect(parseLaneTarget(JSON.stringify(target)).kind).toBe('invalid')
  })
  it('opens retained Curator history through the real router independently of a settings target', () => {
    const target = { kind: 'run_history' as const, workspace: '/workspace A', lane: 'workspace_curator_exact' as const }
    replaceRoute('monitoring', laneTargetParams(target))
    expect(route.value.params.section).toBe('internal-agents')
    expect(route.value.params.view).toBeUndefined()
    expect(parseLaneTarget(route.value.params.lane_target)).toEqual({ kind: 'target', target })
    const current = { kind: 'exact' as const, workspace: target.workspace, lane: 'librarian_exact' as const }
    replaceRoute('monitoring', laneTargetParams(current))
    expect(route.value.params.section).toBe('runtime')
    expect(route.value.params.view).toBe('config')
    expect(parseLaneTarget(route.value.params.lane_target)).toEqual({ kind: 'target', target: current })
    replaceRoute('monitoring', laneTargetParams(current, true))
    expect(parseLaneTarget(route.value.params.lane_target)).toEqual({ kind: 'target',
      target: { ...current, kind: 'run_history' } })
  })
  const browser: RuntimeLaneTarget = { kind: 'browser', workspace: '/workspace', lane: 'automation' }
  const machine: RuntimeLaneTarget = { kind: 'machine', workspace: '/workspace', machine: 'dos' }
  it.each([
    [browser, '[browser.automation]\nbinary = "firefox"\n', '[browser.automation]'],
    [browser, '[browser]\nautomation.binary = "firefox"\n', 'automation.binary'],
    [browser, 'browser = { "automation" = { binary = "firefox" } }\n', '"automation"'],
    [browser, '[browser]\ngeckodriver = "driver"\n', 'geckodriver'],
    [machine, 'machines = { msx = {}, dos = { enabled = false } }\n', 'dos'],
    [machine, '["machines"."dos"]\nenabled = true\n', '["machines"."dos"]'],
  ] as const)('selects the actual TOML node for %j', (target, source, start) => {
    const range = runtimeTargetRange(source, target)
    expect(range).not.toBeNull()
    expect(source.slice(...range!).startsWith(start)).toBe(true)
  })
  it('ignores headings in multiline string values and literal dotted keys', () => {
    const source = 'description = """\n[machines.dos]\nenabled = true\n"""\n"machines.dos" = {}\n[machines.msx]\nenabled = true\n'
    expect(runtimeTargetRange(source, machine)).toBeNull()
    expect(() => runtimeTargetRange('[machines.dos', machine)).toThrow()
  })
  it('confirms only a scalar installation ID at the document root', () => {
    expect(declarationIdentity('"id" = "real"\n[binding]\nid = "decoy"\n')).toBe('real')
    expect(() => declarationIdentity('[binding]\nid = "decoy"\n')).toThrow()
    expect(() => declarationIdentity('id = ["pkg"]\n')).toThrow()
  })
})
