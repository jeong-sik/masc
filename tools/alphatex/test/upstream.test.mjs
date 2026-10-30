// Small examples from alphaTab v1.8.4 (MPL-2.0), used unchanged to exercise
// the upstream language rather than a MASC grammar subset.
// https://github.com/CoderLine/alphaTab/blob/v1.8.4/packages/alphatab/test/importer/AlphaTexImporter.test.ts
// https://github.com/CoderLine/alphaTab/blob/v1.8.4/packages/alphatex/src/metadata/structural/staff.ts
// https://github.com/CoderLine/alphaTab/blob/v1.8.4/packages/alphatex/src/metadata/staff/chord.ts
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { renderScore, createAudioExporter } from '../engine.mjs'

const examples = {
  grace: ':8 3.3{gr} 3.3{gr ob}',
  tuplets: ':8 5.3{tu 5 2}*5',
  repeats: String.raw`\ro 1.3 2.3 3.3 4.3 | 5.3 6.3 7.3 8.3 | \rc 2 1.3 2.3 3.3 4.3 | \ro \rc 3 1.3 2.3 3.3 4.3 |`,
  percussion: String.raw`\instrument "percussion" . 30 31 33 34`,
  voices: String.raw`\track "Piano" \staff{score} \tuning piano \instrument acousticgrandpiano \voice c4 d4 e4 f4 | c4 d4 e4 f4 \voice c3 d3 e3 f3 | c3 d3 e3 f3`,
  bend: '3.3{ b bend gradual (0 4)}',
  slur: ':8 (3.3{ slur s1 } 3.4 3.5) (10.3 {slur s1} 17.4 15.5)',
  numbered: String.raw`\track \staff {score numbered} C4 D4 E4 F4`,
  slash: String.raw`\track \staff {tabs slash} 3.3 4.3 5.3 5.5`,
  chords: String.raw`\chord ("C" 0 1 0 2 3 x) \ts 2 4 (0.1 1.2 0.3 2.4 3.5){ch "C"} (0.1 1.2 0.3 2.4 3.5)`,
}

for (const [name, source] of Object.entries(examples)) {
  test(`official ${name} notation renders and synthesizes audible finite samples`, () => {
    const rendered = renderScore(source, { page: 0 })
    assert.ok(rendered.pages[0].png.length > 0)
    const exporter = createAudioExporter(source)
    let peak = 0
    for (let chunk; (chunk = exporter.render(500));) {
      for (const sample of chunk.samples) {
        assert.ok(Number.isFinite(sample))
        peak = Math.max(peak, Math.abs(sample))
      }
    }
    assert.ok(peak > 0.001, `${name} produced silent audio`)
  })
}
