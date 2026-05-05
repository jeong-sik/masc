import { describe, expect, it } from 'vitest'
import { linesFromShellEvent } from './keeper-shell-drawer'

describe('KeeperShellDrawer event mapping', () => {
  it('maps stdout and stderr chunks to terminal lines', () => {
    const lines = linesFromShellEvent({
      type: 'snapshot',
      keeper: 'sangsu',
      stdout_since: 'one\ntwo\n',
      stderr_since: 'warn\n',
      closed: false,
    })

    expect(lines.map(line => line.text)).toEqual(['one', 'two', 'warn'])
    expect(lines.map(line => line.stream)).toEqual(['stdout', 'stdout', 'stderr'])
  })

  it('surfaces dropped byte evidence as a meta line', () => {
    const lines = linesFromShellEvent({
      type: 'snapshot',
      keeper: 'sangsu',
      stdout_since: 'tail\n',
      stderr_since: '',
      bytes_dropped_stdout: 12,
      bytes_dropped_stderr: 3,
    })

    expect(lines[0]).toEqual({ text: 'dropped 15 older bytes', stream: 'meta' })
  })
})
