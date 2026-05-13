import { afterEach, describe, expect, it } from 'vitest'
import {
  clearLspDiagnosticSnapshot,
  lspDiagnosticSnapshot,
  resolveLspDiagnosticFilePath,
} from './ide-lsp-client'

describe('resolveLspDiagnosticFilePath', () => {
  afterEach(() => {
    lspDiagnosticSnapshot.value = new Map()
  })

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

  it('clears only the normalized diagnostic snapshot for the previous file', () => {
    lspDiagnosticSnapshot.value = new Map([
      [
        'lib/keeper/old.ml',
        [
          {
            file_path: 'lib/keeper/old.ml',
            line: 7,
            severity: 1,
            message: 'old diagnostic',
          },
        ],
      ],
      [
        'lib/keeper/current.ml',
        [
          {
            file_path: 'lib/keeper/current.ml',
            line: 3,
            severity: 2,
            message: 'current diagnostic',
          },
        ],
      ],
    ])

    clearLspDiagnosticSnapshot('lib\\keeper\\old.ml')

    expect(lspDiagnosticSnapshot.value.has('lib/keeper/old.ml')).toBe(false)
    expect(lspDiagnosticSnapshot.value.get('lib/keeper/current.ml')).toHaveLength(1)
  })
})
