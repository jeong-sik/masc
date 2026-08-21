#!/usr/bin/env node
'use strict'

const assert = require('node:assert/strict')
const path = require('node:path')
const ssot = require(path.resolve(__dirname, '../.github/issue-taxonomy.json'))
const { createIssueTaxonomyCore } = require('../.github/scripts/issue-taxonomy-core.cjs')

const taxonomy = createIssueTaxonomyCore(ssot)
const language = ssot.declaration_block_language
const block = (lines) => `\`\`\`${language}\n${lines.join('\n')}\n\`\`\``
const validFields = {}
for (const [axis, spec] of Object.entries(ssot.axes))
  validFields[axis] = Object.keys(spec.values)[0]
for (const flag of Object.keys(ssot.flags)) validFields[flag] = 'false'
const validBlock = block(Object.entries(validFields).map(([key, value]) => `${key}: ${value}`))

assert.deepEqual(taxonomy.severityOrderErrors(), [])
assert.deepEqual(taxonomy.parseDeclaration('plain body'), { present: false })
assert.match(taxonomy.parseDeclaration(`${validBlock}\n${validBlock}`).error, /exactly one/)
assert.match(taxonomy.parseDeclaration(block(['kind: defect', 'kind: gap'])).error, /appears twice/)
assert.match(taxonomy.parseDeclaration(block(['must_do: true'])).error, /unknown key/)

const parsed = taxonomy.parseDeclaration(validBlock)
assert.equal(parsed.present, true)
assert.equal(parsed.error, undefined)
assert.deepEqual(taxonomy.resolve(parsed.fields).errors, [])

const singleAxis = Object.entries(ssot.axes).find(([, spec]) => spec.cardinality === 'one')
assert.ok(singleAxis, 'fixture requires one single-cardinality axis')
const [singleAxisName, singleAxisSpec] = singleAxis
const twoValues = Object.keys(singleAxisSpec.values).slice(0, 2)
assert.equal(twoValues.length, 2, 'fixture requires two values on the single-cardinality axis')
assert.match(
  taxonomy.resolve({ ...validFields, [singleAxisName]: twoValues.join(', ') }).errors.join('\n'),
  /takes exactly one value/,
)

const managedLabel = [...taxonomy.knownLabels][0]
const orphanedManagedLabel = `${Object.keys(ssot.axes)[0]}/removed-value`
const foreignLabels = ['dependencies', 'github-actions', 'main-health']
const current = [managedLabel, orphanedManagedLabel, ...foreignLabels]
const cleared = taxonomy.reconciliationPlan(current, [])
assert.deepEqual(cleared.toRemove.sort(), [managedLabel, orphanedManagedLabel].sort())
assert.deepEqual(cleared.toAdd, [])
for (const label of foreignLabels)
  assert.equal(cleared.toRemove.includes(label), false, `foreign label must survive: ${label}`)

const target = [...taxonomy.knownLabels].find((label) => label !== managedLabel)
assert.ok(target)
const reconciled = taxonomy.reconciliationPlan(current, [target])
assert.deepEqual(reconciled.toAdd, [target])
assert.deepEqual(reconciled.toRemove.sort(), [managedLabel, orphanedManagedLabel].sort())

console.log('issue-taxonomy-core: parser and reconciliation contracts passed')
