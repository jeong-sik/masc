import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { html } from 'htm/preact'
import type { RawTraceTurn } from '../api/dashboard-keeper-prompt'

const api = vi.hoisted(() => ({
  fetchKeeperRawTraces: vi.fn(),
  fetchKeeperRawTrace: vi.fn(),
  fetchKeeperLastPrompt: vi.fn(),
  fetchKeeperOperatorNote: vi.fn(),
  putKeeperOperatorNote: vi.fn(),
}))

vi.mock('../api/dashboard-keeper-prompt', () => api)

import { KeeperTurnInspectorPanel } from './keeper-turn-inspector-panel'

afterEach(() => {
  cleanup()
  vi.clearAllMocks()
})

const KEEPERS = ['analyst', 'code-reviewer']

function noTurns() {
  api.fetchKeeperRawTraces.mockResolvedValue([])
}

describe('KeeperTurnInspectorPanel', () => {
  it('lists a keeper\'s turn files and opens the one that is clicked', async () => {
    const turn = {
      file: 'turn-0007.jsonl',
      traceId: 'trace-0007',
      bytes: 390_000_000,
      census: { state: 'prefix_only', budgetBytes: 262_144 },
      modifiedAt: 1786000000,
    } satisfies RawTraceTurn
    api.fetchKeeperRawTraces.mockResolvedValue([turn])
    const raw = '{"kind":"request","model":"qwen3-6-35b"}'
    api.fetchKeeperRawTrace.mockResolvedValue({
      file: 'turn-0007.jsonl',
      totalRecords: 1,
      offset: 0,
      records: [{ ok: true, raw, record: { kind: 'request', model: 'qwen3-6-35b' } }],
    })

    render(html`<${KeeperTurnInspectorPanel} keepers=${KEEPERS} />`)
    expect(await screen.findByText(/256\.0 KB 초과 · 열어서 집계/)).toBeTruthy()
    fireEvent.click(await screen.findByText('turn-0007.jsonl'))

    // Literal JSONL is the default. A RAW badge must not hide it behind a
    // parsed disclosure tree.
    expect(await screen.findByText(raw)).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'JSON tree' }))
    expect(await screen.findByText(/qwen3-6-35b/)).toBeTruthy()
    expect(api.fetchKeeperRawTrace).toHaveBeenCalledWith(
      'analyst',
      'turn-0007.jsonl',
      expect.objectContaining({ offset: 0 }),
    )
  })

  // A damaged trace must not read as a shorter one: the record that failed to
  // decode holds its position and says why, rather than being dropped.
  it('keeps an undecodable record in place with its reason', async () => {
    const turn = {
      file: 'turn-0008.jsonl',
      traceId: 'trace-0008',
      bytes: 10,
      census: { state: 'whole_file', records: 2 },
      modifiedAt: 1786000000,
    } satisfies RawTraceTurn
    api.fetchKeeperRawTraces.mockResolvedValue([turn])
    api.fetchKeeperRawTrace.mockResolvedValue({
      file: 'turn-0008.jsonl',
      totalRecords: 2,
      offset: 0,
      records: [
        { ok: true, raw: '{"kind":"request"}', record: { kind: 'request' } },
        { ok: false, raw: '{not valid JSON', error: 'not valid JSON' },
      ],
    })

    render(html`<${KeeperTurnInspectorPanel} keepers=${KEEPERS} />`)
    expect(await screen.findByText(/2건/)).toBeTruthy()
    fireEvent.click(await screen.findByText('turn-0008.jsonl'))

    expect(await screen.findByText(/레코드 2 를 읽지 못했습니다: not valid JSON/)).toBeTruthy()
    expect(screen.getByText('{not valid JSON')).toBeTruthy()
  })

  it('shows each prompt block with its own byte count', async () => {
    noTurns()
    api.fetchKeeperLastPrompt.mockResolvedValue({
      keeper: 'analyst',
      capturedAt: 1786000000,
      traceId: 'trace-a',
      absoluteTurn: 42,
      blocks: [
        { id: 'keeper_instructions', bytes: 1024, text: 'you are the analyst' },
        { id: 'operator_note', bytes: 32, text: 'check the cancel record first' },
      ],
      assembled: null,
    })

    render(html`<${KeeperTurnInspectorPanel} keepers=${KEEPERS} />`)
    fireEvent.click(screen.getByRole('tab', { name: 'Typed next prompt' }))

    expect(await screen.findByText('operator_note')).toBeTruthy()
    expect(screen.getByText('1.0 KB')).toBeTruthy()
    // Text is behind a disclosure so a 200 KB block does not open by default.
    expect(screen.queryByText(/check the cancel record first/)).toBeNull()
    fireEvent.click(screen.getByText('operator_note'))
    expect(await screen.findByText(/check the cancel record first/)).toBeTruthy()
  })

  it('writes a note and shows what the server stored', async () => {
    noTurns()
    api.fetchKeeperOperatorNote.mockRejectedValue(new Error('no_note'))
    api.putKeeperOperatorNote.mockResolvedValue({
      keeper: 'analyst',
      pending: true,
      text: 'start from the cancel record',
      createdBy: 'dashboard',
      createdAt: 1786000000,
      consumedTurn: null,
    })

    render(html`<${KeeperTurnInspectorPanel} keepers=${KEEPERS} />`)
    fireEvent.click(screen.getByRole('tab', { name: 'Operator input' }))
    // Absence of a note is the ordinary state, not an error.
    expect(await screen.findByText('대기 중인 노트가 없습니다.')).toBeTruthy()

    fireEvent.input(screen.getByRole('textbox'), {
      target: { value: 'start from the cancel record' },
    })
    fireEvent.click(screen.getByRole('button', { name: '다음 턴에 싣기' }))

    await waitFor(() =>
      expect(api.putKeeperOperatorNote).toHaveBeenCalledWith(
        'analyst',
        'start from the cancel record',
      ))
    expect(await screen.findByText('다음 턴에 실림')).toBeTruthy()
  })

  // The store rejects an oversized note rather than truncating it, and its
  // refusal carries the byte counts. Surfacing it verbatim is the difference
  // between a rejection an operator can act on and one that looks like a bug.
  it('surfaces the server\'s refusal verbatim', async () => {
    noTurns()
    api.fetchKeeperOperatorNote.mockRejectedValue(new Error('no_note'))
    api.putKeeperOperatorNote.mockRejectedValue(
      new Error('note is 5000 bytes; the limit is 4096'),
    )

    render(html`<${KeeperTurnInspectorPanel} keepers=${KEEPERS} />`)
    fireEvent.click(screen.getByRole('tab', { name: 'Operator input' }))
    fireEvent.input(screen.getByRole('textbox'), { target: { value: 'too long' } })
    fireEvent.click(screen.getByRole('button', { name: '다음 턴에 싣기' }))

    expect(await screen.findByText(/note is 5000 bytes; the limit is 4096/)).toBeTruthy()
  })

  it('addresses the keeper that is selected', async () => {
    noTurns()
    render(html`<${KeeperTurnInspectorPanel} keepers=${KEEPERS} />`)
    await waitFor(() => expect(api.fetchKeeperRawTraces).toHaveBeenCalledWith(
      'analyst', 50, expect.anything()))

    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'code-reviewer' } })
    await waitFor(() => expect(api.fetchKeeperRawTraces).toHaveBeenCalledWith(
      'code-reviewer', 50, expect.anything()))
  })

  // The roster arrives after the first render, so a panel built before it must
  // adopt the first keeper rather than staying empty.
  it('adopts the roster when it arrives late', async () => {
    noTurns()
    const { rerender } = render(html`<${KeeperTurnInspectorPanel} keepers=${[]} />`)
    expect(screen.getByText('관측된 keeper 없음')).toBeTruthy()

    rerender(html`<${KeeperTurnInspectorPanel} keepers=${['taskmaster']} />`)
    await waitFor(() => expect(api.fetchKeeperRawTraces).toHaveBeenCalledWith(
      'taskmaster', 50, expect.anything()))
  })
})
