describe('LogViewer kind column', () => {
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
    vi.clearAllMocks()
    vi.resetModules()
    vi.doUnmock('../api/dashboard.js')
    window.location.hash = ''
  })

  it('renders the logs surface with the kind column header and a kind cell per row', async () => {
    const fetchLogs = vi.fn().mockResolvedValue({
      total: 1,
      entries: [
        entry({
          seq: 42,
          level: 'INFO',
          source: 'structured',
          module: 'keeper_tool',
          message: 'read file',
          category: 'tool',
          details: { tool_name: 'tool_read_file', file_path: 'lib/runtime.ml' },
        }),
      ],
    })
    const { LogViewer } = await loadLogs(fetchLogs)
    const { container } = render(h(LogViewer, {}))

    await waitFor(() => expect(container.textContent).toContain('read file'))

    // The table header carries the kind (\"유형\") column the --v2-logs-cols grid sizes.
    const header = container.querySelector('.v2-logs-table-header') as HTMLElement | null
    expect(header).not.toBeNull()
    const headerLabels = [...header!.querySelectorAll('span')].map(s => s.textContent)
    expect(headerLabels).toContain('유형')

    // Each row exposes a kind cell with the resolved label + data-kind attribute.
    const kindCell = container.querySelector('.v2-logs-kind') as HTMLElement | null
    expect(kindCell).not.toBeNull()
    expect(kindCell!.getAttribute('data-kind')).toBe('tool')
    expect(kindCell!.textContent).toBe('TOOL')
  })

  it('renders a kind-aware detail grid and polling caption', async () => {
    const fetchLogs = vi.fn().mockResolvedValue({
      total: 3,
      generated_at_iso: '2026-05-15T01:00:00Z',
      dashboard_surface: '/api/v1/dashboard/logs',
      source: 'masc_log_ring',
      retention: {
        scope: 'dashboard_logs',
        durable_store: '/Users/dancer/me/.masc/logs/system_log_2026-05-15.jsonl',
      },
      latest_seq: 3,
      entries: [
        entry({
          seq: 1,
          ts: '2026-05-14T00:00:00Z',
          level: 'INFO',
          module: 'keeper_tool',
          category: 'tool',
          message: 'tool event',
          details: { tool_name: 'fs.ls' },
        }),
        entry({
          seq: 2,
          ts: '2026-05-14T00:00:01Z',
          level: 'INFO',
          module: 'keeper_turn',
          category: 'routine',
          turn_id: 'turn-2',
          message: 'turn event',
        }),
        entry({
          seq: 3,
          ts: '2026-05-14T00:00:02Z',
          level: 'WARN',
          module: 'keeper_fsm',
          category: 'fsm',
          message: 'lifecycle event',
        }),
      ],
    })

    const { LogViewer } = await loadLogs(fetchLogs)
    const { container } = render(h(LogViewer, {}))

    await waitFor(() => expect(container.textContent).toContain('tool event'))
    expect(container.textContent).toContain('turn event')
    expect(container.textContent).toContain('lifecycle event')
    expect(container.querySelector('.v2-logs-live')?.textContent).toContain('WS open')

    const toolChip = container.querySelector('[data-testid="logs-filter-tool"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(toolChip)
    })
    await waitFor(() => expect(container.textContent).toContain('tool event'))
    expect(container.textContent).not.toContain('turn event')
    expect(container.textContent).not.toContain('lifecycle event')

    const turnChip = container.querySelector('[data-testid="logs-filter-turn"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(turnChip)
    })
    await waitFor(() => expect(container.textContent).toContain('turn event'))
    expect(container.textContent).not.toContain('tool event')
    expect(container.textContent).not.toContain('lifecycle event')

    const allChip = container.querySelector('[data-testid="logs-filter-all"]') as HTMLButtonElement
    await act(async () => {
      fireEvent.click(allChip)
    })
    await waitFor(() => expect(container.textContent).toContain('turn event'))
    expect(container.textContent).toContain('tool event')
    expect(container.textContent).toContain('lifecycle event')
  })
})
