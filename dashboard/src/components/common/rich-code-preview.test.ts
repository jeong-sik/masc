// @vitest-environment jsdom

import { cleanup, fireEvent, render, waitFor } from '@testing-library/preact'
import { html } from 'htm/preact'
import { afterEach, describe, expect, it, vi } from 'vitest'
import {
  AlphaTexScoreView,
  MidiScorePlayer,
  measureScoreRenderWidth,
  resolveAlphaTabThemePalette,
  resolveCssColorToRgba,
} from './alphatab-score'
import {
  PELE_FENCE_TAGS,
  RichCodePreviewCard,
  enhanceRichCode,
  resolvePeleThemeVars,
  richCodeKind,
} from './rich-code-preview'
import { StructuredChartView, parseChartFenceJson } from './structured-chart'
import { parseMarkdownToBlocks } from '../chat/markdown-blocks'
import { ChatArtifactPanel, extractArtifactGroups } from '../chat/artifact-panel'
import type { KeeperConversationEntry } from '../../types'

// Minimal valid SMF Format 0 MIDI file (1 track, middle C quarter note, 120 BPM).
const MINIMAL_MIDI_BYTES = new Uint8Array([
  0x4d, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x01, 0x01, 0xe0,
  0x4d, 0x54, 0x72, 0x6b, 0x00, 0x00, 0x00, 0x13,
  0x00, 0xff, 0x51, 0x03, 0x07, 0xa1, 0x20,
  0x00, 0x90, 0x3c, 0x64,
  0x83, 0x60, 0x80, 0x3c, 0x00,
  0x00, 0xff, 0x2f, 0x00,
])

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
  document.documentElement.removeAttribute('data-theme')
})

describe('AlphaTex score rendering, theme palette, profile switching, diagnostics, and synth fallback', () => {
  it('enforces minimum 560px render width when host clientWidth is 0 and resolves dark/light palettes', () => {
    const el = document.createElement('div')
    Object.defineProperty(el, 'clientWidth', { value: 0, configurable: true })
    expect(measureScoreRenderWidth(el)).toBe(560)

    document.documentElement.setAttribute('data-theme', 'dark')
    const darkPalette = resolveAlphaTabThemePalette(el)
    expect(darkPalette.isLight).toBe(false)
    expect(darkPalette.mainGlyph).toBeTruthy()
    expect(darkPalette.staffLine).toBeTruthy()

    document.documentElement.setAttribute('data-theme', 'light')
    const lightPalette = resolveAlphaTabThemePalette(el)
    expect(lightPalette.isLight).toBe(true)
    expect(lightPalette.mainGlyph).not.toBe(darkPalette.mainGlyph)

    expect(resolveCssColorToRgba('#123456', '#000000')).toBe('#123456')
    expect(resolveCssColorToRgba('rgb(10, 20, 30)', '#000000')).toBe('rgb(10, 20, 30)')
    expect(resolveCssColorToRgba('', '#abcdef')).toBe('#abcdef')
  })

  it('renders valid AlphaTex SVG, switches StaveProfile (악보+탭 / 탭 / 악보), opens zoom modal, and reports missing AudioContext gracefully', async () => {
    const view = render(html`
      <${AlphaTexScoreView} source=${'\\title "Test Riff" \\tempo 120 . 0.6 2.6 3.6 0.5'} />
    `)

    await waitFor(() => {
      const svgHost = view.getByTestId('alphatex-score-svg')
      expect(svgHost.querySelector('svg')).not.toBeNull()
    }, { timeout: 10000 })

    // Default fretted AlphaTex selects 악보+탭
    const scoreTabBtn = view.getByRole('button', { name: '악보+탭' })
    const tabBtn = view.getByRole('button', { name: '탭' })
    const scoreBtn = view.getByRole('button', { name: '악보' })
    expect(scoreTabBtn.getAttribute('aria-pressed')).toBe('true')

    fireEvent.click(tabBtn)
    expect(tabBtn.getAttribute('aria-pressed')).toBe('true')
    fireEvent.click(scoreBtn)
    expect(scoreBtn.getAttribute('aria-pressed')).toBe('true')

    // Click zoom opens ChatPreviewModal
    fireEvent.click(view.getByRole('button', { name: '악보 확대 보기' }))
    expect(document.querySelector('[role="dialog"][aria-modal="true"]')).not.toBeNull()
    fireEvent.click(document.querySelector('[role="dialog"] button[aria-label="닫기"]')!)

    // Clicking Play in jsdom (no AudioContext) surfaces graceful inline notice instead of throwing
    fireEvent.click(view.getByRole('button', { name: '악보 재생' }))
    const errBox = await view.findByTestId('alphatab-synth-error')
    expect(errBox.textContent).toContain('Web Audio')
  })

  it('renders explicit inline diagnostic card on malformed AlphaTex instead of removing host', async () => {
    const view = render(html`
      <${AlphaTexScoreView} source=${'\\tempo not-a-number . ::: invalid %%%'} />
    `)

    const errCard = await view.findByTestId('alphatex-error-card', {}, { timeout: 10000 })
    expect(errCard.querySelector('[role="alert"]')).not.toBeNull()
    expect(errCard.textContent).toContain('AlphaTex')
    expect(errCard.querySelector('pre code')?.textContent).toContain('not-a-number')
  })

  it('parses SMF MIDI bytes in <MidiScorePlayer> and toggles inline notation without using <audio>', async () => {
    const view = render(html`<${MidiScorePlayer} bytes=${MINIMAL_MIDI_BYTES} title="melody.mid" />`)

    await waitFor(() => {
      expect(view.getByTestId('midi-player')).toBeTruthy()
    }, { timeout: 10000 })

    expect(view.container.querySelector('audio')).toBeNull()
    expect(view.container.textContent).toContain('♩=120')
    expect(view.container.textContent).toContain('1 트랙')

    // Toggle inline notation view
    fireEvent.click(view.getByRole('button', { name: '악보 보기' }))
    await waitFor(() => {
      const svgHost = view.getByTestId('alphatex-score-svg')
      expect(svgHost.querySelector('svg')).not.toBeNull()
    }, { timeout: 10000 })
  })
})

describe('Pele 33-type diagram support & theme variables', () => {
  it('recognizes all 33 Pele diagram/chart fence tags plus alphatex and chart', () => {
    const expectedPeleTags = [
      'mermaid', 'pele', 'xychart', 'xychart-beta', 'pie', 'quadrant', 'quadrantchart',
      'radar', 'radar-beta', 'sankey', 'sankey-beta', 'treemap', 'treemap-beta',
      'gantt', 'timeline', 'kanban', 'mindmap', 'venn', 'venn-beta', 'wardley',
      'ishikawa', 'c4', 'architecture', 'flowchart', 'sequence', 'class', 'er',
      'state', 'gitgraph', 'journey', 'packet', 'requirement', 'block', 'swimlane',
      'agentflow', 'eventmodeling', 'cynefin', 'treeview', 'railroad', 'usecase',
    ]
    for (const tag of expectedPeleTags) {
      expect(PELE_FENCE_TAGS.has(tag)).toBe(true)
      expect(richCodeKind(tag)).toBe('diagram')
    }
    expect(richCodeKind('alphatex')).toBe('alphatex')
    expect(richCodeKind('atex')).toBe('alphatex')
    expect(richCodeKind('chart')).toBe('chart')
    expect(richCodeKind('typescript')).toBeNull()
  })

  it('resolves all Pele theme CSS variables including --pele-accent and --pele-series-1..8', () => {
    const vars = resolvePeleThemeVars(document.createElement('div'))
    expect(vars['--pele-fg']).toBeTruthy()
    expect(vars['--pele-bg']).toBeTruthy()
    expect(vars['--pele-accent']).toBeTruthy()
    for (let i = 1; i <= 8; i += 1) {
      expect(vars[`--pele-series-${i}`]).toBeTruthy()
    }
  })

  it('renders a Pele diagram with injected theme vars, lightbox zoom, and explicit error banner on invalid syntax', async () => {
    const view = render(html`
      <${RichCodePreviewCard}
        kind="diagram"
        lang="pie"
        source=${'pie title Distribution\n  "Alpha" : 40\n  "Beta" : 60'}
      />
    `)

    await waitFor(() => {
      const img = view.container.querySelector('img.rich-code-diagram-img') as HTMLImageElement | null
      expect(img).not.toBeNull()
      const decodedSvg = decodeURIComponent(img!.src.replace(/^data:image\/svg\+xml;charset=utf-8,/, ''))
      expect(decodedSvg).toContain('--pele-accent:')
      expect(decodedSvg).toContain('--pele-series-1:')
      expect(decodedSvg).toContain('--pele-series-8:')
    }, { timeout: 10000 })

    // Open lightbox
    fireEvent.click(view.getByRole('button', { name: '다이어그램 확대 보기' }))
    expect(document.querySelector('[role="dialog"][aria-modal="true"]')).not.toBeNull()
    fireEvent.click(document.querySelector('[role="dialog"] button[aria-label="닫기"]')!)

    // Invalid syntax shows error card with source fallback
    cleanup()
    const bad = render(html`
      <${RichCodePreviewCard} kind="diagram" lang="mermaid" source=${'totally_unknown_directive >>> ???'} />
    `)
    const errCard = await bad.findByTestId('pele-error-card', {}, { timeout: 10000 })
    expect(errCard.querySelector('[role="alert"]')).not.toBeNull()
    expect(errCard.querySelector('pre code')?.textContent).toContain('totally_unknown_directive')
  })

  it('mounts and cleans up rich previews cleanly via enhanceRichCode', () => {
    const root = document.createElement('div')
    root.innerHTML = '<pre><code class="language-chart">{"type":"bar","title":"Q1","labels":["A","B"],"series":[{"label":"Rev","values":[10,20]}]}</code></pre>'
    const unmount = enhanceRichCode(root)
    expect(root.querySelector('[data-testid="chart-preview-card"]')).not.toBeNull()
    expect(root.querySelector('[data-testid="structured-chart"]')).not.toBeNull()
    unmount()
    expect(root.querySelector('[data-testid="chart-preview-card"]')).toBeNull()
  })
})

describe('Structured charts (line / bar / area / pie) & markdown-blocks fence parsing', () => {
  it('parses valid ```chart JSON fences and returns null for malformed JSON', () => {
    const bar = parseChartFenceJson(JSON.stringify({
      type: 'bar',
      title: 'Latency (ms)',
      labels: ['P50', 'P95', 'P99'],
      yLabel: 'ms',
      series: [{ label: 'API', values: [-2.5, 14.2, 42.5] }],
    }))
    expect(bar).toMatchObject({
      t: 'chart',
      chartType: 'bar',
      title: 'Latency (ms)',
      labels: ['P50', 'P95', 'P99'],
      yLabel: 'ms',
    })

    expect(parseChartFenceJson('{ invalid json')).toBeNull()
    expect(parseChartFenceJson('{"title":"No series"}')).toBeNull()
  })

  it('renders line, bar, area, and pie charts with negative/decimal ticks, X labels, and interactive hover readout', () => {
    const baseSeries = [{ label: 'Delta', values: [-12.5, 0, 24.5, 42.5] }]
    const labels = ['Jan', 'Feb', 'Mar', 'Apr']

    for (const chartType of ['line', 'bar', 'area'] as const) {
      cleanup()
      const view = render(html`
        <${StructuredChartView}
          block=${{ t: 'chart', chartType, title: `Test ${chartType}`, labels, series: baseSeries, xLabel: 'Month', yLabel: 'Score' }}
        />
      `)
      const chart = view.getByTestId('structured-chart')
      expect(chart.getAttribute('data-chart-type')).toBe(chartType)
      expect(chart.textContent).toContain('-12.5')
      expect(chart.textContent).toContain('42.5')
      expect(chart.textContent).toContain('Jan')
      expect(chart.textContent).toContain('Apr')

      if (chartType === 'bar') {
        const rect = chart.querySelector('rect')!
        expect(rect).not.toBeNull()
        fireEvent.mouseEnter(rect)
      } else {
        const dot = chart.querySelector('circle')!
        expect(dot).not.toBeNull()
        fireEvent.mouseEnter(dot)
      }
      expect(view.getByTestId('chart-hover-readout').textContent).toContain('Delta: -12.5')
    }

    // Pie chart
    cleanup()
    const pieView = render(html`
      <${StructuredChartView}
        block=${{
          t: 'chart',
          chartType: 'pie',
          title: 'Budget Split',
          labels: ['Compute', 'Storage', 'Network'],
          series: [{ label: 'USD', values: [50, 30, 20] }],
        }}
      />
    `)
    const pieEl = pieView.getByTestId('structured-chart')
    expect(pieEl.getAttribute('data-chart-type')).toBe('pie')
    expect(pieEl.querySelectorAll('path').length).toBe(3)
    expect(pieEl.textContent).toContain('Compute')
    expect(pieEl.textContent).toContain('50%')
  })

  it('parses Pele diagram fences and ```chart JSON fences in parseMarkdownToBlocks (with code fallback on invalid JSON)', () => {
    const md = [
      '```radar-beta',
      'title Skills',
      '```',
      '',
      '```chart',
      '{"type":"area","title":"Throughput","labels":["T1","T2"],"series":[{"label":"req/s","values":[100,150]}]}',
      '```',
      '',
      '```chart',
      '{ not valid json }',
      '```',
    ].join('\n')

    const blocks = parseMarkdownToBlocks(md)
    expect(blocks).toHaveLength(3)
    expect(blocks[0]).toMatchObject({ t: 'mermaid', caption: 'radar-beta' })
    expect(blocks[1]).toMatchObject({ t: 'chart', chartType: 'area', title: 'Throughput' })
    expect(blocks[2]).toMatchObject({ t: 'code', cap: 'chart' })
  })

  it('extracts and previews chart and alphatex artifacts in ChatArtifactPanel', () => {
    const entries: KeeperConversationEntry[] = [
      {
        id: 'turn-1',
        role: 'assistant',
        source: 'direct_assistant',
        delivery: 'delivered',
        label: 'Keeper',
        text: '',
        blocks: [
          {
            t: 'chart',
            chartType: 'bar',
            title: 'Turn Metrics',
            labels: ['A', 'B'],
            series: [{ label: 'Count', values: [3, 7] }],
          },
          {
            t: 'code',
            cap: 'alphatex',
            html: '0.6 2.6',
            source: '0.6 2.6',
          },
        ],
      },
    ]

    const groups = extractArtifactGroups(entries)
    expect(groups).toHaveLength(1)
    expect(groups[0]!.items.map((i) => i.kind)).toEqual(['chart', 'alphatex'])

    const view = render(html`<${ChatArtifactPanel} entries=${entries} />`)
    const openBtns = view.getAllByRole('button', { name: '미리보기' })
    fireEvent.click(openBtns[0]!)
    expect(view.container.querySelector('[data-artifact-preview="chart"]')).not.toBeNull()
    expect(view.getByTestId('structured-chart')).toBeTruthy()
  })
})
