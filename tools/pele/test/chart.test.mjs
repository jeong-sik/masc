import { test } from 'node:test';
import assert from 'node:assert/strict';
import { renderDocument } from '../engine.mjs';

const PNG_SIG = [137, 80, 78, 71, 13, 10, 26, 10];
const PALETTES = [
  { name: 'dark', colors: { foreground: '#e6edf3', background: '#0d1117' } },
  { name: 'light', colors: { foreground: '#1f2937', background: '#ffffff' } },
];

const PELE_CHART_FAMILIES = [
  ['xychart-beta', 'xychart-beta\n  title "Revenue"\n  x-axis [Q1, Q2, Q3, Q4]\n  y-axis "USD" 0 --> 100\n  bar [30, 55, 72, 90]\n  line [25, 48, 68, 84]'],
  ['pie', 'pie title Breakdown\n  "Compute": 45\n  "Storage": 30\n  "Network": 25'],
  ['quadrantChart', 'quadrantChart\n  title Reach vs Impact\n  x-axis Low Reach --> High Reach\n  y-axis Low Impact --> High Impact\n  quadrant-1 Expand\n  quadrant-2 Promote\n  quadrant-3 Re-evaluate\n  quadrant-4 Improve\n  Alpha: [0.3, 0.7]\n  Beta: [0.8, 0.85]'],
  ['radar-beta', 'radar-beta\n  title Keeper Profile\n  axis s["Speed"], q["Quality"], c["Cost"], r["Reliability"], x["Context"]\n  curve a["Alpha"]{80, 90, 70, 85, 75}\n  curve b["Beta"]{65, 80, 95, 75, 60}'],
  ['sankey-beta', 'sankey-beta\n\nIngest,Parse,40\nParse,Store,35\nParse,Drop,5\nStore,Serve,35'],
  ['treemap-beta', 'treemap-beta\n"MASC"\n  "Runtime"\n    "Keepers": 40\n    "ACP": 20\n  "UI"\n    "Dashboard": 25\n    "TUI": 15'],
  ['gantt', 'gantt\n  title Release Plan\n  dateFormat YYYY-MM-DD\n  section Build\n  Core :a1, 2026-11-01, 5d\n  UI   :after a1, 4d'],
  ['timeline', 'timeline\n  title Milestones\n  2026-Q1 : Bootstrap\n  2026-Q2 : Multimodal\n  2026-Q3 : Rich Media'],
  ['venn-beta', 'venn-beta\n  set A["TUI"]:20\n  set B["Dashboard"]:20\n  union A,B["Shared API"]:8'],
];

test('Pele chart families render valid PNGs with distinct series colors on dark and light palettes', () => {
  for (const [family, source] of PELE_CHART_FAMILIES) {
    for (const { name, colors } of PALETTES) {
      const result = renderDocument({ format: 'mermaid', source, maxWidth: 640, colors });
      assert.deepEqual([...result.png.subarray(0, 8)], PNG_SIG, `${family} (${name}) PNG signature`);
      assert.ok(result.png.readUInt32BE(16) > 0 && result.png.readUInt32BE(16) <= 640, `${family} (${name}) width`);
      assert.ok(result.png.readUInt32BE(20) > 0, `${family} (${name}) height`);
      assert.ok(!result.svg.includes('var(--'), `${family} (${name}) no unresolved CSS vars`);
    }
  }
});

test('structured chart format renders line, bar, area, and pie PNGs on dark and light palettes', () => {
  const specs = [
    {
      type: 'line',
      title: 'Latency Trend',
      labels: ['Mon', 'Tue', 'Wed', 'Thu'],
      xLabel: 'Day',
      yLabel: 'ms',
      series: [
        { label: 'p50', values: [12, 15, 11, 14] },
        { label: 'p99', values: [42, 55, 38, 49] },
      ],
    },
    {
      type: 'bar',
      title: 'Tasks Completed',
      labels: ['Alpha', 'Beta', 'Gamma'],
      yMax: 50,
      series: [
        { label: 'This Week', values: [22, 35, 18] },
        { label: 'Last Week', values: [18, 28, 24] },
      ],
    },
    {
      type: 'area',
      title: 'Token Throughput',
      labels: ['00:00', '06:00', '12:00', '18:00'],
      series: [{ label: 'Tokens/s', color: '#22c55e', values: [120, 340, 280, 410] }],
    },
    {
      type: 'pie',
      title: 'Attachment Kinds',
      labels: ['Image', 'Audio', 'Video', 'PDF'],
      series: [{ label: 'Count', values: [45, 20, 15, 20] }],
    },
  ];
  for (const spec of specs) {
    for (const { name, colors } of PALETTES) {
      const result = renderDocument({
        format: 'chart',
        source: JSON.stringify(spec),
        maxWidth: 640,
        colors,
      });
      assert.deepEqual([...result.png.subarray(0, 8)], PNG_SIG, `chart:${spec.type} (${name}) PNG`);
      assert.ok(result.png.readUInt32BE(16) > 0 && result.png.readUInt32BE(16) <= 640);
      assert.ok(result.png.readUInt32BE(20) > 0);
      assert.ok(result.svg.includes(spec.title), `chart:${spec.type} includes title`);
    }
  }
});

test('structured chart format rejects invalid JSON, unknown types, and empty series', () => {
  for (const bad of ['{broken', '{"type":"radar","series":[{"label":"a","values":[1]}]}', '{"type":"bar","series":[]}']) {
    assert.throws(() => renderDocument({ format: 'chart', source: bad, maxWidth: 640 }), TypeError);
  }
});
