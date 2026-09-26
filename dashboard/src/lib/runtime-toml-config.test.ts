import { describe, expect, it } from 'vitest'
import { getStaticTOMLValue, parseTOML } from 'toml-eslint-parser'
import {
  createRuntimeTomlBinding,
  deleteRuntimeTomlKey,
  enabledRuntimeIds,
  getRuntimeTomlKey,
  isReservedRuntimeTomlId,
  isValidRuntimeTomlIdFormat,
  parseRuntimeTomlEnvironment,
  declaredRuntimeLaneCandidates,
  runtimeTomlImpactSummary,
  setRuntimeTomlBindingField,
  setRuntimeTomlDefault,
  setRuntimeTomlKey,
  setRuntimeTomlModelField,
  setRuntimeTomlProviderCredential,
  setRuntimeTomlProviderField,
  setRuntimeTomlStringArrayKey,
  cascadeDeleteProvider,
} from './runtime-toml-config'

const sourceText = `[runtime]
default = "runpod_mtp.qwen"

[providers.runpod_mtp]
display-name = "RunPod"
protocol = "openai-http"
endpoint = "https://runpod.example/v1"

[providers.runpod_mtp.credentials]
type = "env"
key = "RUNPOD_API_KEY"

[models.qwen]
api-name = "qwen"
max-context = 128000
tools-support = true
thinking-support = true
streaming = true

[runpod_mtp.qwen]
is-default = true
max-concurrent = 4
keep-alive = "10m"
`

describe('runtime TOML dashboard editing helpers', () => {
  it('edits a quoted provider table in place', () => {
    for (const quote of ['"', "'"]) {
      const header = `providers.${quote}runpod_mtp${quote}`
      const quoted = sourceText.replaceAll('providers.runpod_mtp', header)
      expect(parseRuntimeTomlEnvironment(quoted).providers[0]?.id).toBe('runpod_mtp')
      expect(getRuntimeTomlKey(quoted, 'providers.runpod_mtp', 'display-name')).toBe('"RunPod"')
      const edited = setRuntimeTomlProviderField(quoted, 'runpod_mtp', 'exact-body-timeout-s', 1200)
      expect(edited).toContain(`[${header}]`)
      expect(edited).not.toContain('[providers.runpod_mtp]')
      expect(getRuntimeTomlKey(edited, 'providers.runpod_mtp', 'exact-body-timeout-s')).toBe('1200')
    }
  })

  it.each(['providers . "runpod_mtp"', "'providers' . 'runpod_mtp'", 'providers . "runpod\\u005fmtp"'])('edits semantic provider table %s without duplicating it', header => {
    const source = sourceText.replaceAll('providers.runpod_mtp', header)
    const edited = setRuntimeTomlProviderField(source, 'runpod_mtp', 'exact-body-timeout-s', 15)
    const decoded = getStaticTOMLValue(parseTOML(edited))
    expect(decoded).toMatchObject({ providers: { runpod_mtp: { 'exact-body-timeout-s': 15 } } })
    expect(edited).toContain(`[${header}]`)
    expect(edited).not.toContain('[providers.runpod_mtp]')
    expect(parseRuntimeTomlEnvironment(edited).providers[0]?.id).toBe('runpod_mtp')
  })

  it('uses decoded keys and source ranges for value edits while preserving comments', () => {
    const source = String.raw`[providers . "p"]
"exact\u002dbody-timeout-s" = 10 # keep this operator note
note = """
[providers.p]
exact-body-timeout-s = 900
"""
`
    const edited = setRuntimeTomlProviderField(source, 'p', 'exact-body-timeout-s', 15)
    expect(edited).toContain(String.raw`"exact\u002dbody-timeout-s" = 15 # keep this operator note`)
    expect(getRuntimeTomlKey(edited, 'providers.p', 'exact-body-timeout-s')).toBe('15')
    expect(getStaticTOMLValue(parseTOML(edited))).toMatchObject({ providers: { p: { 'exact-body-timeout-s': 15 } } })
    expect(edited).toContain('exact-body-timeout-s = 900')
    expect(parseRuntimeTomlEnvironment(edited).providers.map(provider => provider.id)).toEqual(['p'])
  })

  it('deletes a provider by parsed table identity, including escaped keys and bindings', () => {
    const source = String.raw`[runtime]
default = 'p.m'
[runtime . assignments]
"nick\u0030cave" = 'p.m'
[providers . "\u0070"]
protocol = 'openai-http'
[providers . "p" . credentials]
type = 'env'
key = 'FIXTURE_TOKEN'
['p' . "m"]
`
    const edited = cascadeDeleteProvider(source, 'p')
    const parsed = getStaticTOMLValue(parseTOML(edited))
    expect(parsed).toEqual({ runtime: { assignments: {} } })
  })

  it('preserves dotted model identity through model and binding edits', () => {
    const source = `[providers.p]\nprotocol='openai-http'\n[models."m.v1"]\napi-name='m.v1'\nmax-context=128000\n[p."m.v1"]\nmax-concurrent=2\n`
    const edited = setRuntimeTomlBindingField(setRuntimeTomlModelField(source, 'm.v1', 'max-context', 64000), 'p.m.v1', 'max-concurrent', 3)
    expect(getStaticTOMLValue(parseTOML(edited))).toMatchObject({ models: { 'm.v1': { 'max-context': 64000 } }, p: { 'm.v1': { 'max-concurrent': 3 } } })
    expect(parseRuntimeTomlEnvironment(edited).models[0]?.id).toBe('m.v1')
    expect(createRuntimeTomlBinding(edited, 'p', 'm.v1')).toBe(edited)
  })

  it('projects quoted provider keys in a draft without reparsing their contents as TOML syntax', () => {
    const source = `[providers."draft provider"]\nprotocol='openai-http'\n[providers."draft provider".credentials]\ntype='env'\nkey='FIXTURE_KEY'\n`
    const edited = setRuntimeTomlProviderField(source, 'draft provider', 'exact-body-timeout-s', 15)
    expect(parseRuntimeTomlEnvironment(edited).providers[0]).toMatchObject({
      id: 'draft provider', protocol: 'openai-http', credentialKey: 'FIXTURE_KEY',
    })
    expect(getStaticTOMLValue(parseTOML(edited))).toMatchObject({ providers: { 'draft provider': { 'exact-body-timeout-s': 15 } } })
  })

  it('refuses to create a binding that an inline table already owns', () => {
    expect(() => createRuntimeTomlBinding('p = { m = { enabled = true } }', 'p', 'm')).toThrow()
  })

  it('projects provider, model, and binding fields from runtime.toml source', () => {
    const environment = parseRuntimeTomlEnvironment(sourceText)

    expect(environment.defaultRuntimeId).toBe('runpod_mtp.qwen')
    expect(environment.assignments).toEqual({})
    expect(environment.providers[0]).toMatchObject({
      id: 'runpod_mtp',
      enabled: true,
      displayName: 'RunPod',
      protocol: 'openai-http',
      transportKind: 'endpoint',
      endpoint: 'https://runpod.example/v1',
      credentialType: 'env',
      credentialKey: 'RUNPOD_API_KEY',
    })
    expect(environment.models[0]).toMatchObject({
      id: 'qwen',
      apiName: 'qwen',
      maxContext: 128000,
      toolsSupport: true,
      thinkingSupport: true,
      jsonSupport: null,
      streaming: true,
    })
    expect(environment.bindings[0]).toMatchObject({
      id: 'runpod_mtp.qwen',
      enabled: true,
      maxConcurrent: 4,
      keepAlive: '10m',
    })
  })

  it('parses and edits explicit provider and binding disable state', () => {
    let next = setRuntimeTomlProviderField(sourceText, 'runpod_mtp', 'enabled', false)
    next = setRuntimeTomlBindingField(next, 'runpod_mtp.qwen', 'enabled', false)

    const environment = parseRuntimeTomlEnvironment(next)
    expect(environment.providers[0]?.enabled).toBe(false)
    expect(environment.bindings[0]?.enabled).toBe(false)
    expect(enabledRuntimeIds(environment)).toEqual([])
    expect(next.match(/^enabled = false$/gm)).toHaveLength(2)
  })

  it('projects the Codex official-client subscription boundary without credentials', () => {
    const codexSource = `[runtime]
default = "codex_subscription.spark"

[providers.codex_subscription]
display-name = "Codex Subscription"
protocol = "codex-app-server"
command = "/usr/local/bin/codex"
is-non-interactive = true

[models.spark]
api-name = "gpt-5.3-codex-spark"
max-context = 131072

[codex_subscription.spark]
`

    const environment = parseRuntimeTomlEnvironment(codexSource)
    expect(environment.providers[0]).toMatchObject({
      protocol: 'codex-app-server',
      transportKind: 'command',
      command: '/usr/local/bin/codex',
      credentialType: 'none',
      isNonInteractive: true,
    })
  })

  it('keeps account homes separate while reusing a model for official clients', () => {
    let next = setRuntimeTomlProviderField(sourceText, 'codex_second', 'display-name', 'Codex second')
    next = setRuntimeTomlProviderField(next, 'codex_second', 'protocol', 'codex-app-server')
    next = setRuntimeTomlProviderField(next, 'codex_second', 'command', 'codex')
    next = setRuntimeTomlProviderField(next, 'codex_second', 'is-non-interactive', true)
    next = setRuntimeTomlProviderField(next, 'codex_second', 'account-home', '/tmp/codex-second')
    const provider = parseRuntimeTomlEnvironment(next).providers.find(item => item.id === 'codex_second')
    expect(provider?.accountHome).toBe('/tmp/codex-second')
    expect(next).toContain('account-home = "/tmp/codex-second"')
    next = setRuntimeTomlProviderField(next, 'codex_second', 'account-home', null)
    expect(parseRuntimeTomlEnvironment(next).providers.find(item => item.id === 'codex_second')?.accountHome).toBe('')
  })

  it('projects runtime routing lanes and keeper assignments from runtime.toml source', () => {
    const withRouting = `${sourceText.replace(
      'default = "runpod_mtp.qwen"',
      'default = "runpod_mtp.qwen"',
    )}

[runtime.assignments]
sangsu = "runpod_mtp.qwen"
mad-improver = "runpod_mtp.qwen"
`

    const environment = parseRuntimeTomlEnvironment(withRouting)

    expect(environment.assignments).toEqual({
      sangsu: 'runpod_mtp.qwen',
      'mad-improver': 'runpod_mtp.qwen',
    })
  })

  // Regression for the live ~/.masc/config/runtime.toml shape: keeper names
  // under [runtime.assignments] are written as quoted TOML keys
  // (`"nick0cave" = "..."`), not the bare keys used above. The dashboard
  // rendered every keeper as "default 폴백" because the parser silently
  // dropped every quoted-key line instead of erroring or reading it.
  it('projects keeper assignments written with quoted TOML keys', () => {
    const withQuotedAssignments = `${sourceText}

[runtime.assignments]
"nick0cave" = "ollama_cloud.deepseek-v4-flash"
"mad-improver" = "glm-coding.glm-5-turbo"
`

    const environment = parseRuntimeTomlEnvironment(withQuotedAssignments)

    expect(environment.assignments).toEqual({
      nick0cave: 'ollama_cloud.deepseek-v4-flash',
      'mad-improver': 'glm-coding.glm-5-turbo',
    })
  })

  it('lists declared [runtime.lanes.<id>] tables, bare or quoted, as lane ids', () => {
    const withLanes = `${sourceText}

[runtime.lanes.coding]
candidates = ["ollama_cloud.deepseek-v4-flash"]

[runtime.lanes."ollama_cloud.minimax-m3"]
candidates = ["ollama_cloud.minimax-m3"]

[runtime.lanes.coding.extra]
note = "not a lane header"
`

    const environment = parseRuntimeTomlEnvironment(withLanes)

    expect(environment.laneIds).toEqual(['coding', 'ollama_cloud.minimax-m3'])
    expect(parseRuntimeTomlEnvironment(sourceText).laneIds).toEqual([])
  })

  it('reads a lane\'s declared candidates only from its own table', () => {
    const withLanes = `${sourceText}

[runtime.lanes.coding]
# head first
candidates = [
  "rt-a", # primary
  'rt-x',
  "rt-b",
]

[runtime.lanes."vision.fast"]
candidates = ["rt-c"]

[runtime.lanes.mixed]
candidates = ["rt-a", 3]
`

    expect(declaredRuntimeLaneCandidates(withLanes, 'coding')).toEqual(['rt-a', 'rt-x', 'rt-b'])
    expect(declaredRuntimeLaneCandidates(withLanes, 'vision.fast')).toEqual(['rt-c'])
    expect(declaredRuntimeLaneCandidates(withLanes, 'mixed')).toBeNull()
    expect(declaredRuntimeLaneCandidates(
      '[runtime.lanes.twice]\ncandidates = ["rt-a"]\ncandidates = ["rt-b"]\n',
      'twice',
    )).toBeNull()
    expect(declaredRuntimeLaneCandidates(withLanes, 'missing')).toBeNull()
    expect(declaredRuntimeLaneCandidates(
      '[runtime]\nlanes = { coding = { candidates = ["rt-a"] } }\n',
      'coding',
    )).toBeNull()
    expect(declaredRuntimeLaneCandidates('[runtime.lanes."a\\"b"]\ncandidates = ["rt-a"]\n', 'a"b')).toEqual(['rt-a'])
  })

  it('uses parsed TOML identity and arrays for lane declarations', () => {
    const source = String.raw`description = """
[runtime.lanes.fake]
candidates = ["not-real"]
"""
[ runtime . lanes . "coded\u002elane" ]
"candidates" = ["rt\u002da", 'unadmitted#slot', "rt-b"]
[runtime.lanes.other.child]
candidates = ["not-a-lane"]
`
    expect(parseRuntimeTomlEnvironment(source).laneIds).toEqual(['coded.lane'])
    expect(declaredRuntimeLaneCandidates(source, 'coded.lane')).toEqual(['rt-a', 'unadmitted#slot', 'rt-b'])
    expect(declaredRuntimeLaneCandidates(source, 'fake')).toBeNull()
    expect(declaredRuntimeLaneCandidates(source, 'other')).toBeNull()
    const invalid = source + '\n[runtime.lanes.bad]\ncandidates = ["a"\n'
    expect(declaredRuntimeLaneCandidates(invalid, 'coded.lane')).toBeNull()
    expect(parseRuntimeTomlEnvironment(invalid).laneIds).toEqual([])
  })

  it('updates an existing quoted-key assignment line in place instead of appending a duplicate', () => {
    const withQuotedAssignments = `${sourceText}

[runtime.assignments]
"nick0cave" = "ollama_cloud.deepseek-v4-flash"
`

    const next = setRuntimeTomlKey(
      withQuotedAssignments,
      'runtime.assignments',
      'nick0cave',
      'ollama_cloud.kimi-k2-6',
    )

    expect(getRuntimeTomlKey(next, 'runtime.assignments', 'nick0cave')).toBe(
      '"ollama_cloud.kimi-k2-6"',
    )
    expect(next.match(/nick0cave/g)).toHaveLength(1)
    // The original quoted key spelling must survive an in-place value update --
    // only the value should change, not the key syntax the TOML author chose.
    expect(next).toContain('"nick0cave" = "ollama_cloud.kimi-k2-6"')
    expect(next).not.toContain('\nnick0cave = ')
  })

  it('rewrites a multi-line TOML string array without leaving stale elements behind', () => {
    const withFusionPreset = `${sourceText}

[fusion.presets.trio]
panel = [
  "old.a",
  "old.b",
]
judge = "meta.old"
`

    const next = setRuntimeTomlStringArrayKey(
      withFusionPreset,
      'fusion.presets.trio',
      'panel',
      ['new.a', 'new.b'],
    )

    const preset = next.split('[fusion.presets.trio]')[1] ?? ''
    expect(preset).toContain('panel = ["new.a", "new.b"]')
    expect(preset).toContain('judge = "meta.old"')
    expect(preset).not.toContain('old.a')
    expect(preset).not.toContain('old.b')
  })

  it('does not write a keeper name requiring quotes as an invalid bare key', () => {
    const withAssignmentsSection = `${sourceText}

[runtime.assignments]
sangsu = "runpod_mtp.qwen"
`

    const next = setRuntimeTomlKey(
      withAssignmentsSection,
      'runtime.assignments',
      'qa king',
      'runpod_mtp.qwen',
    )

    expect(next).toContain('"qa king" = "runpod_mtp.qwen"')
    expect(getRuntimeTomlKey(next, 'runtime.assignments', 'qa king')).toBe(
      '"runpod_mtp.qwen"',
    )
  })

  it('reports malformed TOML without publishing a partial assignment projection', () => {
    const withMalformedLine = `${sourceText}

[runtime.assignments]
"nick0cave" = "ollama_cloud.deepseek-v4-flash"
this line has no equals sign
`

    const environment = parseRuntimeTomlEnvironment(withMalformedLine)

    expect(environment.assignments).toEqual({})
    expect(environment.parseError).toMatch(/TOML \d+:\d+:/)
    expect(environment.warnings).toEqual([environment.parseError])
    expect(() => setRuntimeTomlDefault(withMalformedLine, 'p.m')).toThrow()
    expect(runtimeTomlImpactSummary(sourceText, withMalformedLine)).toBeNull()
  })

  it('patches the runtime default without touching other sections', () => {
    const next = setRuntimeTomlDefault(sourceText, 'openai.gpt')

    expect(next).toContain('default = "openai.gpt"')
    expect(next).toContain('[providers.runpod_mtp]')
    expect(next).toContain('endpoint = "https://runpod.example/v1"')
  })

  it('switches provider transport by deleting the opposite transport field', () => {
    const next = setRuntimeTomlProviderField(
      sourceText,
      'runpod_mtp',
      'command',
      'provider-runtime --serve',
    )

    expect(next).toContain('command = "provider-runtime --serve"')
    expect(next).not.toContain('endpoint = "https://runpod.example/v1"')
  })

  it('updates model and binding fields with TOML scalar formatting', () => {
    let next = setRuntimeTomlModelField(sourceText, 'qwen', 'max-context', 262144)
    next = setRuntimeTomlModelField(next, 'qwen', 'streaming', false)
    next = setRuntimeTomlBindingField(next, 'runpod_mtp.qwen', 'num-ctx', 131072)

    expect(next).toContain('max-context = 262144')
    expect(next).toContain('streaming = false')
    expect(next).toContain('num-ctx = 131072')
  })

  it('rewrites credential shape and removes stale credential fields', () => {
    const next = setRuntimeTomlProviderCredential(
      sourceText,
      'runpod_mtp',
      'file',
      '/run/secrets/runpod-token',
    )

    expect(next).toContain('type = "file"')
    expect(next).toContain('path = "/run/secrets/runpod-token"')
    expect(next).not.toContain('key = "RUNPOD_API_KEY"')
  })

  it('deletes credential sections instead of writing blank credential values', () => {
    const next = setRuntimeTomlProviderCredential(sourceText, 'runpod_mtp', 'env', '   ')

    expect(next).not.toContain('[providers.runpod_mtp.credentials]')
    expect(next).not.toContain('key = ""')
  })

  it('trims env credential names before writing them', () => {
    const next = setRuntimeTomlProviderCredential(
      sourceText,
      'runpod_mtp',
      'env',
      ' OLLAMA_CLOUD_API_KEY ',
    )

    expect(next).toContain('key = "OLLAMA_CLOUD_API_KEY"')
  })

  it('trims inline credential values before writing them', () => {
    const next = setRuntimeTomlProviderCredential(
      sourceText,
      'runpod_mtp',
      'inline',
      '  sk-inline-secret  ',
    )

    expect(next).toContain('value = "sk-inline-secret"')
    expect(next).not.toContain('  sk-inline-secret  ')
  })

  it('deletes optional keys when requested', () => {
    const next = deleteRuntimeTomlKey(sourceText, 'runpod_mtp.qwen', 'keep-alive')

    expect(next).not.toContain('keep-alive = "10m"')
    expect(next).toContain('max-concurrent = 4')
  })

  it('summarizes runtime.toml apply impact from before and after source', () => {
    const next = `${setRuntimeTomlDefault(sourceText, 'openai.gpt')}

[runtime.assignments]
sangsu = "openai.gpt"

[models.extra]
api-name = "extra"
`

    const impact = runtimeTomlImpactSummary(sourceText, next)

    expect(impact?.defaultRuntimeChanged).toBe(true)
    expect(impact?.defaultRuntimeBefore).toBe('runpod_mtp.qwen')
    expect(impact?.defaultRuntimeAfter).toBe('openai.gpt')
    expect(impact?.runtimeAssignmentsChanged).toBe(true)
    expect(impact?.providerCountDelta).toBe(0)
    expect(impact?.modelCountDelta).toBe(1)
    expect(impact?.bindingCountDelta).toBe(0)
    expect(impact?.lineDelta).toBeGreaterThan(0)
    expect(impact?.charDelta).toBeGreaterThan(0)
  })

  it('does not report assignment-only reformatting as an assignment change', () => {
    const before = `${sourceText}

[runtime.assignments]
sangsu = "runpod_mtp.qwen"
`
    const after = `${sourceText}

[runtime.assignments]
  sangsu   =   "runpod_mtp.qwen" # same assignment
`

    const impact = runtimeTomlImpactSummary(before, after)

    expect(impact?.runtimeAssignmentsChanged).toBe(false)
  })

  it('cascades provider deletion to credentials, bindings, and default runtime', () => {
    const next = cascadeDeleteProvider(sourceText, 'runpod_mtp')
    const env = parseRuntimeTomlEnvironment(next)

    expect(env.providers.length).toBe(0)
    expect(env.bindings.length).toBe(0)
    expect(next).not.toContain('default = "runpod_mtp.qwen"')
    expect(next).not.toContain('[providers.runpod_mtp.credentials]')
  })

  it('deletes quoted provider and credential tables with their binding', () => {
    for (const quote of ['"', "'"]) {
      const quoted = sourceText
        .replaceAll('providers.runpod_mtp', `providers.${quote}runpod_mtp${quote}`)
        .replace('[runpod_mtp.qwen]', `[${quote}runpod_mtp${quote}.${quote}qwen${quote}]`)
        + '\n[runtime.assignments]\nsangsu = "runpod_mtp.qwen"\n'
      expect(parseRuntimeTomlEnvironment(quoted).bindings.map(binding => binding.id))
        .toEqual(['runpod_mtp.qwen'])

      const next = cascadeDeleteProvider(quoted, 'runpod_mtp')
      expect(parseRuntimeTomlEnvironment(next).providers).toEqual([])
      expect(next).not.toContain(`[providers.${quote}runpod_mtp${quote}]`)
      expect(next).not.toContain(`[providers.${quote}runpod_mtp${quote}.credentials]`)
      expect(next).not.toContain(`[${quote}runpod_mtp${quote}.${quote}qwen${quote}]`)
      expect(next).not.toContain('default = "runpod_mtp.qwen"')
      expect(next).not.toContain('sangsu = "runpod_mtp.qwen"')
    }
  })

  it('retargets default and clears the dependent route when deleting a provider with a fallback binding', () => {
    const withFallback = `${sourceText.replace(
      'default = "runpod_mtp.qwen"',
      'default = "runpod_mtp.qwen"',
    )}

[providers.openai]
display-name = "OpenAI"
protocol = "openai-compatible-http"
endpoint = "https://api.openai.example/v1"

[models.gpt]
api-name = "gpt"
max-context = 64000
streaming = true

[openai.gpt]
max-concurrent = 1

[runtime.assignments]
sangsu = "runpod_mtp.qwen"
`

    const next = cascadeDeleteProvider(withFallback, 'runpod_mtp')
    const env = parseRuntimeTomlEnvironment(next)

    expect(env.defaultRuntimeId).toBe('openai.gpt')
    expect(env.assignments).toEqual({})
    expect(env.providers.map(p => p.id)).toEqual(['openai'])
    expect(env.bindings.map(b => b.id)).toEqual(['openai.gpt'])
    expect(next).toContain('default = "openai.gpt"')
    expect(next).not.toContain('[providers.runpod_mtp]')
    expect(next).not.toContain('[runpod_mtp.qwen]')
    expect(next).not.toContain('sangsu = "runpod_mtp.qwen"')
  })

  it('does not delete reserved runtime namespaces when a legacy provider id is reserved', () => {
    const withReservedProvider = `${sourceText}

[providers.runtime]
display-name = "Legacy Reserved"
protocol = "openai-compatible-http"
endpoint = "https://reserved.example/v1"

[runtime.assignments]
sangsu = "runpod_mtp.qwen"
`

    const next = cascadeDeleteProvider(withReservedProvider, 'runtime')
    const env = parseRuntimeTomlEnvironment(next)

    expect(next).not.toContain('[providers.runtime]')
    expect(next).toContain('[runtime.assignments]')
    expect(env.defaultRuntimeId).toBe('runpod_mtp.qwen')
    expect(env.assignments).toEqual({ sangsu: 'runpod_mtp.qwen' })
    expect(env.providers.map(provider => provider.id)).toEqual(['runpod_mtp'])
    expect(env.bindings.map(binding => binding.id)).toEqual(['runpod_mtp.qwen'])
  })

  it('can delete max-context field by setting it to null', () => {
    const next = setRuntimeTomlModelField(sourceText, 'qwen', 'max-context', null)
    const env = parseRuntimeTomlEnvironment(next)

    expect(env.models[0]?.maxContext).toBeNull()
    expect(next).not.toContain('max-context =')
  })

  it('reads model capabilities from the nested [models.<id>.capabilities] section', () => {
    const sourceWithCaps = `${sourceText}
[models.structured]
api-name = "structured-v1"
max-context = 200000
tools-support = true
thinking-support = true
streaming = true

[models.structured.capabilities]
supports-tool-choice = true
supports-response-format-json = true
supports-structured-output = false
supports-multimodal-inputs = true
thinking-control-format = "reasoning-effort"
`
    const env = parseRuntimeTomlEnvironment(sourceWithCaps)

    const structuredModel = env.models.find(m => m.id === 'structured')
    // thinking-control-format is present in the fixture (mirroring a real
    // runtime.toml) but intentionally NOT projected into RuntimeTomlModel:
    // Agent Core request-building never reads this key (masc #21521), so the parser
    // does not resurface it as a client-editable field.
    expect(structuredModel).toMatchObject({
      jsonSupport: true,
      toolChoice: true,
      structuredOutput: false,
      multimodal: true,
    })
    expect(structuredModel).not.toHaveProperty('thinkingControlFormat')
  })

  it('treats absent capability keys as unknown (null), never a fabricated false', () => {
    // qwen in the base fixture declares no [models.qwen.capabilities] section.
    const env = parseRuntimeTomlEnvironment(sourceText)
    const qwen = env.models.find(m => m.id === 'qwen')
    expect(qwen).toMatchObject({
      jsonSupport: null,
      toolChoice: null,
      structuredOutput: null,
      multimodal: null,
    })
  })

  it('derives multimodal from supports-image-input when the multimodal key is absent', () => {
    const source = `${sourceText}
[models.vision]
api-name = "vision-v1"

[models.vision.capabilities]
supports-image-input = true
`
    const env = parseRuntimeTomlEnvironment(source)
    expect(env.models.find(m => m.id === 'vision')?.multimodal).toBe(true)
  })

  it('reads per-M binding prices when declared, and leaves them null otherwise', () => {
    const priced = parseRuntimeTomlEnvironment(
      sourceText.replace('keep-alive = "10m"', 'keep-alive = "10m"\nprice-input = 0.14\nprice-output = 0.28'),
    )
    const pricedBinding = priced.bindings.find(b => b.id === 'runpod_mtp.qwen')
    expect(pricedBinding?.priceInput).toBe(0.14)
    expect(pricedBinding?.priceOutput).toBe(0.28)

    const bare = parseRuntimeTomlEnvironment(sourceText)
    const bareBinding = bare.bindings.find(b => b.id === 'runpod_mtp.qwen')
    expect(bareBinding?.priceInput).toBeNull()
    expect(bareBinding?.priceOutput).toBeNull()
  })

  it('writes the JSON capability to the nested capabilities section using the server SSOT key', () => {
    const next = setRuntimeTomlModelField(sourceText, 'qwen', 'json-support', true)
    expect(next).toContain('[models.qwen.capabilities]')
    expect(next).toContain('supports-response-format-json = true')
    // the legacy top-level key the server ignored must not be written
    expect(next).not.toContain('json-support = true')
    // and it round-trips back through the parser
    expect(parseRuntimeTomlEnvironment(next).models.find(m => m.id === 'qwen')?.jsonSupport).toBe(true)
  })

  it('creates a brand-new provider from fields set on a not-yet-existing id', () => {
    let next = setRuntimeTomlProviderField(sourceText, 'brand-new', 'display-name', 'Brand New')
    next = setRuntimeTomlProviderField(next, 'brand-new', 'protocol', 'openai-compatible-http')
    next = setRuntimeTomlProviderField(next, 'brand-new', 'endpoint', 'https://brand-new.example/v1')
    next = setRuntimeTomlProviderCredential(next, 'brand-new', 'env', 'BRAND_NEW_API_KEY')

    const env = parseRuntimeTomlEnvironment(next)
    const provider = env.providers.find(p => p.id === 'brand-new')
    expect(provider).toMatchObject({
      id: 'brand-new',
      displayName: 'Brand New',
      protocol: 'openai-compatible-http',
      transportKind: 'endpoint',
      endpoint: 'https://brand-new.example/v1',
      credentialType: 'env',
      credentialKey: 'BRAND_NEW_API_KEY',
    })
    // Existing provider/model/binding untouched.
    expect(env.providers.find(p => p.id === 'runpod_mtp')).toBeDefined()
  })

  it('creates a brand-new model from fields set on a not-yet-existing id', () => {
    let next = setRuntimeTomlModelField(sourceText, 'brand-new-model', 'api-name', 'brand-new-model-v1')
    next = setRuntimeTomlModelField(next, 'brand-new-model', 'max-context', 32000)
    next = setRuntimeTomlModelField(next, 'brand-new-model', 'streaming', true)

    const env = parseRuntimeTomlEnvironment(next)
    const model = env.models.find(m => m.id === 'brand-new-model')
    expect(model).toMatchObject({
      id: 'brand-new-model',
      apiName: 'brand-new-model-v1',
      maxContext: 32000,
      toolsSupport: false,
      streaming: true,
    })
  })

  describe('createRuntimeTomlBinding', () => {
    it('creates an empty pin section for a provider x model pair', () => {
      const next = createRuntimeTomlBinding(sourceText, 'runpod_mtp', 'qwen2')
      expect(next).toContain('[runpod_mtp.qwen2]')

      const env = parseRuntimeTomlEnvironment(next)
      expect(env.bindings.find(b => b.id === 'runpod_mtp.qwen2')).toMatchObject({
        providerId: 'runpod_mtp',
        modelId: 'qwen2',
        isDefault: false,
        maxConcurrent: null,
      })
    })

    it('is a no-op when the binding already exists', () => {
      const next = createRuntimeTomlBinding(sourceText, 'runpod_mtp', 'qwen')
      expect(next).toBe(sourceText)
    })
  })

  describe('isValidRuntimeTomlIdFormat', () => {
    // Matches the TOML bare-key grammar (ASCII letters/digits/underscore/dash,
    // no restriction on the first character) -- a leading '_'/'-' is a valid
    // bare key to both keyLineMatch's tokenizer and the backend TOML parser,
    // so this form must accept ids that already work in raw-edited runtime.toml.
    it.each(['ollama_cloud', 'deepseek-v4-flash', 'a', 'A1-b_2', '-leading-hyphen', '_leading-underscore'])(
      'accepts %s',
      id => {
        expect(isValidRuntimeTomlIdFormat(id)).toBe(true)
      },
    )

    it.each(['', 'has.dot', 'has space', 'has[bracket]'])('rejects %s', id => {
      expect(isValidRuntimeTomlIdFormat(id)).toBe(false)
    })
  })

  describe('isReservedRuntimeTomlId', () => {
    it.each([
      'providers',
      'models',
      'runtime',
      'system',
      'routes',
      'profiles',
      'web_search',
      'exec',
      'egress',
      'skills',
      'voice',
      'vision',
    ])(
      'flags reserved top-level namespace %s',
      id => {
        expect(isReservedRuntimeTomlId(id)).toBe(true)
      },
    )

    it('does not flag an ordinary id', () => {
      expect(isReservedRuntimeTomlId('ollama_cloud')).toBe(false)
    })
  })
})
