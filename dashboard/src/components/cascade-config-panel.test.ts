import { describe, expect, it } from 'vitest'

import {
  buildCascadeBindingSnippet,
  buildCascadeThinkingAliasSnippet,
  buildCascadeTierSnippet,
} from './cascade-config-panel'

describe('cascade config authoring snippets', () => {
  it('builds provider-model binding snippets with client capacity', () => {
    expect(buildCascadeBindingSnippet('runpod', 'qwen-coder', 2)).toBe([
      '[runpod.qwen-coder]',
      'is-default = false',
      'max-concurrent = 2',
    ].join('\n'))
  })

  it('builds thinking alias snippets without provider-specific model logic', () => {
    expect(buildCascadeThinkingAliasSnippet('ollama-cloud', 'qwen3', 8192)).toBe([
      '[ollama-cloud.qwen3.thinking]',
      'temperature = 0.2',
      'thinking-enabled = true',
      'thinking-budget = 8192',
    ].join('\n'))
  })

  it('clamps tier max-concurrent snippets to at least one', () => {
    expect(buildCascadeTierSnippet('primary', 'runpod.qwen-coder', 0)).toContain('max-concurrent = 1')
  })
})
