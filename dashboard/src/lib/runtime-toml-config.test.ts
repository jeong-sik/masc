import { describe, expect, it } from 'vitest'
import {
  createRuntimeTomlBinding,
  deleteRuntimeTomlKey,
  isReservedRuntimeTomlId,
  isValidRuntimeTomlIdFormat,
  parseRuntimeTomlEnvironment,
  runtimeTomlImpactSummary,
  setRuntimeTomlBindingField,
  setRuntimeTomlDefault,
  setRuntimeTomlModelField,
  setRuntimeTomlProviderCredential,
  setRuntimeTomlProviderField,
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
  it('projects provider, model, and binding fields from runtime.toml source', () => {
    const environment = parseRuntimeTomlEnvironment(sourceText)

    expect(environment.defaultRuntimeId).toBe('runpod_mtp.qwen')
    expect(environment.librarianRuntimeId).toBe('')
    expect(environment.crossVerifierRuntimeId).toBe('')
    expect(environment.assignments).toEqual({})
    expect(environment.providers[0]).toMatchObject({
      id: 'runpod_mtp',
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
      maxConcurrent: 4,
      keepAlive: '10m',
    })
  })

  it('projects runtime routing lanes and keeper assignments from runtime.toml source', () => {
    const withRouting = `${sourceText.replace(
      'default = "runpod_mtp.qwen"',
      'default = "runpod_mtp.qwen"\nlibrarian = "runpod_mtp.qwen"\ncross_verifier = "runpod_mtp.qwen"',
    )}

[runtime.assignments]
sangsu = "runpod_mtp.qwen"
mad-improver = "runpod_mtp.qwen"
`

    const environment = parseRuntimeTomlEnvironment(withRouting)

    expect(environment.librarianRuntimeId).toBe('runpod_mtp.qwen')
    expect(environment.crossVerifierRuntimeId).toBe('runpod_mtp.qwen')
    expect(environment.assignments).toEqual({
      sangsu: 'runpod_mtp.qwen',
      'mad-improver': 'runpod_mtp.qwen',
    })
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

    expect(impact.defaultRuntimeChanged).toBe(true)
    expect(impact.defaultRuntimeBefore).toBe('runpod_mtp.qwen')
    expect(impact.defaultRuntimeAfter).toBe('openai.gpt')
    expect(impact.runtimeAssignmentsChanged).toBe(true)
    expect(impact.providerCountDelta).toBe(0)
    expect(impact.modelCountDelta).toBe(1)
    expect(impact.bindingCountDelta).toBe(0)
    expect(impact.lineDelta).toBeGreaterThan(0)
    expect(impact.charDelta).toBeGreaterThan(0)
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

    expect(impact.runtimeAssignmentsChanged).toBe(false)
  })

  it('cascades provider deletion to credentials, bindings, and default runtime', () => {
    const next = cascadeDeleteProvider(sourceText, 'runpod_mtp')
    const env = parseRuntimeTomlEnvironment(next)
    
    expect(env.providers.length).toBe(0)
    expect(env.bindings.length).toBe(0)
    expect(next).not.toContain('default = "runpod_mtp.qwen"')
    expect(next).not.toContain('[providers.runpod_mtp.credentials]')
  })

  it('can delete max-context field by setting it to null', () => {
    const next = setRuntimeTomlModelField(sourceText, 'qwen', 'max-context', null)
    const env = parseRuntimeTomlEnvironment(next)
    
    expect(env.models[0]?.maxContext).toBeNull()
    expect(next).not.toContain('max-context =')
  })

  it('extracts json-support from model config', () => {
    const sourceWithJson = `${sourceText}\n[models.structured]\njson-support = true\n`
    const env = parseRuntimeTomlEnvironment(sourceWithJson)

    const structuredModel = env.models.find(m => m.id === 'structured')
    expect(structuredModel?.jsonSupport).toBe(true)
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
    it.each(['ollama_cloud', 'deepseek-v4-flash', 'a', 'A1-b_2'])('accepts %s', id => {
      expect(isValidRuntimeTomlIdFormat(id)).toBe(true)
    })

    it.each(['', 'has.dot', 'has space', '-leading-hyphen', '_leading-underscore', 'has[bracket]'])(
      'rejects %s',
      id => {
        expect(isValidRuntimeTomlIdFormat(id)).toBe(false)
      },
    )
  })

  describe('isReservedRuntimeTomlId', () => {
    it.each(['providers', 'models', 'runtime', 'system', 'routes', 'profiles', 'web_search'])(
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
