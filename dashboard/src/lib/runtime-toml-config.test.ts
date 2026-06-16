import { describe, expect, it } from 'vitest'
import {
  deleteRuntimeTomlKey,
  parseRuntimeTomlEnvironment,
  setRuntimeTomlBindingField,
  setRuntimeTomlDefault,
  setRuntimeTomlModelField,
  setRuntimeTomlProviderCredential,
  setRuntimeTomlProviderField,
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
      streaming: true,
    })
    expect(environment.bindings[0]).toMatchObject({
      id: 'runpod_mtp.qwen',
      maxConcurrent: 4,
      keepAlive: '10m',
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

  it('deletes optional keys when requested', () => {
    const next = deleteRuntimeTomlKey(sourceText, 'runpod_mtp.qwen', 'keep-alive')

    expect(next).not.toContain('keep-alive = "10m"')
    expect(next).toContain('max-concurrent = 4')
  })
})
