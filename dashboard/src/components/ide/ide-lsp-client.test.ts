import { describe, expect, it } from 'vitest'
import { resolveLspDiagnosticFilePath } from './ide-lsp-client'

describe('resolveLspDiagnosticFilePath', () => {
  it('keeps safe relative diagnostic URIs as IDE file paths', () => {
    expect(resolveLspDiagnosticFilePath(
      'file://lib/keeper/runtime.ml',
      'lib/keeper/current.ml',
    )).toBe('lib/keeper/runtime.ml')
  })

  it('maps absolute diagnostic URIs only when they match the current IDE file suffix', () => {
    expect(resolveLspDiagnosticFilePath(
      'file:///Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/keeper/current.ml',
      'lib/keeper/current.ml',
    )).toBe('lib/keeper/current.ml')
    expect(resolveLspDiagnosticFilePath(
      'file:///Users/dancer/me/workspace/yousleepwhen/masc-mcp/lib/keeper/other.ml',
      'lib/keeper/current.ml',
    )).toBeNull()
  })

  it('ignores missing or unsafe diagnostic URIs instead of falling back to the current file', () => {
    expect(resolveLspDiagnosticFilePath(undefined, 'lib/keeper/current.ml')).toBeNull()
    expect(resolveLspDiagnosticFilePath(
      'file:///tmp/current.ml',
      'lib/keeper/current.ml',
    )).toBeNull()
  })
})
