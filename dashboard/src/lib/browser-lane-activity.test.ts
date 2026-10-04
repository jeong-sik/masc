import { execFileSync } from 'node:child_process'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { describe, expect, it } from 'vitest'
import { readBrowserActivity, writeBrowserActivity } from './browser-lane-activity'

describe('Browser activity TOML boundaries', () => {
  it.each([
    '', '[browser]', 'browser = {}', '[browser.automation]',
    '[browser]\nautomation = {}', 'browser.automation = {}',
    '"browser.automation" = false',
    'notes="""[browser.automation]\nenabled=false"""',
  ])('defaults omitted activity to on without interpreting other content: %s', source => {
    for (const lane of ['live', 'automation', 'stagehand'] as const)
      expect(readBrowserActivity(source, lane)).toEqual({ enabled: true })
  })
  it.each([
    '[browser.automation]\nenabled=false # note\n',
    '["brow\\u0073er".\'automation\']\n"enabled"=false # note\n',
    'browser.automation.enabled=false # note\n',
    '[browser]\nautomation.enabled=false # note\n',
    'browser={automation={enabled=false}} # note\n',
    'browser={automation.enabled=false} # note\n',
    '[browser]\nautomation={enabled=false} # note\n',
  ])('reads and edits the selected flag in supported forms: %s', source => {
    expect(readBrowserActivity(source, 'automation').enabled).toBe(false)
    const changed = writeBrowserActivity(source, 'automation', true)
    expect(readBrowserActivity(changed, 'automation').enabled).toBe(true)
    expect(readBrowserActivity(changed, 'live').enabled).toBe(true)
    expect(readBrowserActivity(changed, 'stagehand').enabled).toBe(true)
    expect(changed).toContain('# note')
  })
  it('keeps flat driver paths intact when editing Live and moves them only for Automation', () => {
    const source = '[browser]\ngeckodriver="/driver"\nbinary="/firefox"\n[browser.stagehand]\nenabled=false\nchrome="/chrome"\nextension="/extension"\nprofile="/profile"\n[providers.extra]\nlabel="keep"\n'
    const live = writeBrowserActivity(source, 'live', false)
    expect(live).toContain('geckodriver="/driver"\nbinary="/firefox"')
    const automation = writeBrowserActivity(live, 'automation', false)
    expect(automation).toContain('geckodriver = "/driver"')
    expect(automation).toContain('binary = "/firefox"')
    expect(automation).toContain('chrome="/chrome"\nextension="/extension"\nprofile="/profile"')
    expect(automation).toContain('[providers.extra]\nlabel="keep"')
    for (const lane of ['live', 'automation', 'stagehand'] as const)
      expect(readBrowserActivity(automation, lane).enabled).toBe(false)
  })
  it.each([
    'browser=false', 'browser=[]', '[[browser]]',
    '[browser]\nautomation=false', '[[browser.live]]',
    '[browser.automation]\nenabled="false"',
    '[browser.stagehand]\nenabled=0', '[browser.live.enabled]',
    '[browser]\ngeckodriver=42', '[browser]\ngeckodriver="/driver"\nautomation={}',
    '[browser.other]', '[browser.live]\nother=true',
  ])('refuses invalid Browser structure: %s', source => {
    expect(() => readBrowserActivity(source, 'automation')).toThrow()
    expect(() => writeBrowserActivity(source, 'automation', false)).toThrow()
  })
})

// Run the actual reader/editor in separate processes. The old implementation
// mutates global prototypes for these keys; failing cases must not contaminate
// the test runner or another scenario.
describe('Browser prototype isolation', () => {
  it.each([
    { source: '[__proto__.browser.automation]\nenabled=false', rejects: false },
    { source: '__proto__.browser.live.enabled=false', rejects: false },
    { source: '[providers.__proto__]\nbase_url="https://fixture.invalid"', rejects: false },
    { source: 'providers={__proto__={token_env="FIXTURE_ONLY"}}', rejects: false },
    { source: '[browser.__proto__]\nenabled=false', rejects: true },
    { source: '[browser]\n__proto__=true', rejects: true },
    { source: 'browser={__proto__={enabled=false}}', rejects: true },
    { source: '[browser.automation]\n__proto__=true', rejects: true },
    { source: '[browser.automation.__proto__]\nenabled=false', rejects: true },
    { source: '[browser.constructor]\nenabled=false', rejects: true },
    { source: '[browser.live]\ntoString=false', rejects: true },
  ])('does not mutate or inherit keys: $source', ({ source, rejects }) => {
    const moduleUrl = pathToFileURL(resolve('src/lib/browser-lane-activity.ts')).href
    const script = `
      import { readBrowserActivity, writeBrowserActivity } from ${JSON.stringify(moduleUrl)};
      const before = Object.getOwnPropertyDescriptors(Object.prototype);
      const capture = fn => { try { return { value: fn() }; } catch (error) { return { error: String(error) }; } };
      const source = ${JSON.stringify(source)};
      const read = capture(() => readBrowserActivity(source, 'automation'));
      const write = capture(() => readBrowserActivity(writeBrowserActivity(source, 'automation', false), 'automation'));
      const empty = ['live','automation','stagehand'].map(lane => capture(() => readBrowserActivity('', lane)));
      const after = Object.getOwnPropertyDescriptors(Object.prototype);
      const unchanged = Reflect.ownKeys(before).length === Reflect.ownKeys(after).length && Reflect.ownKeys(before).every(key => {
        const a=before[key], b=after[key]; return b && a.value===b.value && a.get===b.get && a.set===b.set
          && a.writable===b.writable && a.enumerable===b.enumerable && a.configurable===b.configurable;
      });
      console.log(JSON.stringify({ unchanged, read, write, empty }));
    `
    const result = JSON.parse(execFileSync(process.execPath,
      ['--import', 'tsx', '--input-type=module', '--eval', script], { encoding: 'utf8' }))
    expect(result.unchanged).toBe(true)
    expect(result.empty).toEqual(Array.from({ length: 3 }, () => ({ value: { enabled: true } })))
    if (rejects) {
      expect(result.read.error).toBeTypeOf('string'); expect(result.write.error).toBeTypeOf('string')
    } else {
      expect(result.read).toEqual({ value: { enabled: true } })
      expect(result.write).toEqual({ value: { enabled: false } })
    }
  })
})
