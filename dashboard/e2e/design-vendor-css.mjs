// Vendors a prototype stylesheet into src/styles/keeper-v2/, applying the one
// transform the repo requires: whole-pixel font-size literals that already have
// a --fs-<N> token become var(--fs-<N>) (scripts/lint/no-raw-font-size-px.sh).
// The token values are 1:1 with the pixels, so the render is unchanged.
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const protoDir = resolve(here, '../prototypes/keeper-v2/styles')
const vendorDir = resolve(here, '../src/styles/keeper-v2')
const TOKENIZED = /font-size:\s*(9|10|11|12|13|14|16|20|28|36|56)px\b/g

for (const name of process.argv.slice(2)) {
  const src = readFileSync(`${protoDir}/${name}.css`, 'utf8')
  let n = 0
  const out = src.replace(TOKENIZED, (_m, px) => { n++; return `font-size: var(--fs-${px})` })
  writeFileSync(`${vendorDir}/${name}.css`, out)
  console.log(`${name}.css vendored (${n} font-size literals tokenized)`)
}
