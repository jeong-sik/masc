'use strict'

function createIssueTaxonomyCore(ssot) {
  const language = ssot.declaration_block_language
  const declaredKeys = new Set([...Object.keys(ssot.axes), ...Object.keys(ssot.flags)])
  const knownLabels = new Set()
  for (const axis of Object.values(ssot.axes))
    for (const value of Object.values(axis.values)) knownLabels.add(value.label)
  for (const flag of Object.values(ssot.flags)) knownLabels.add(flag.label)

  const orderedValues = (spec) => spec.severity_order || Object.keys(spec.values)

  function severityOrderErrors() {
    const errors = []
    for (const [axis, spec] of Object.entries(ssot.axes)) {
      if (!spec.severity_order) continue
      const ordered = [...spec.severity_order].sort().join(',')
      const declared = Object.keys(spec.values).sort().join(',')
      if (ordered !== declared)
        errors.push(`axis '${axis}': severity_order does not cover its values (${ordered} vs ${declared}).`)
    }
    return errors
  }

  function parseDeclaration(body) {
    const pattern = new RegExp('```' + language + '\\s*\\n([\\s\\S]*?)```', 'g')
    const blocks = [...(body || '').matchAll(pattern)]
    if (blocks.length === 0) return { present: false }
    if (blocks.length > 1)
      return {
        present: true,
        error: `the body carries ${blocks.length} ${language} blocks; keep exactly one`,
      }
    const fields = {}
    for (const raw of blocks[0][1].split('\n')) {
      const line = raw.trim()
      if (!line || line.startsWith('#')) continue
      const separator = line.indexOf(':')
      if (separator < 0)
        return { present: true, error: `line is not key: value -> ${line}` }
      const key = line.slice(0, separator).trim().toLowerCase()
      if (!declaredKeys.has(key))
        return {
          present: true,
          error: `unknown key '${key}'. Keys: ${[...declaredKeys].join(', ')}`,
        }
      if (key in fields) return { present: true, error: `key '${key}' appears twice` }
      fields[key] = line.slice(separator + 1).trim().toLowerCase()
    }
    return { present: true, fields }
  }

  function splitList(value) {
    return value
      .replace(/^\[|\]$/g, '')
      .split(',')
      .map((item) => item.trim())
      .filter(Boolean)
  }

  function resolve(fields) {
    const add = []
    const errors = []
    for (const [axis, spec] of Object.entries(ssot.axes)) {
      const raw = fields[axis]
      if (raw === undefined || raw === '') {
        if (spec.required) errors.push(`axis '${axis}' is not declared.`)
        continue
      }
      const values = splitList(raw)
      if (spec.cardinality === 'one' && values.length !== 1) {
        errors.push(`axis '${axis}' takes exactly one value, got ${values.length}: ${raw}`)
        continue
      }
      for (const value of values) {
        const hit = spec.values[value]
        if (!hit)
          errors.push(
            `'${axis}: ${value}' is not in the vocabulary. Allowed: ${orderedValues(spec).join(', ')}`,
          )
        else add.push(hit.label)
      }
    }
    for (const [flag, spec] of Object.entries(ssot.flags)) {
      const raw = fields[flag] || ''
      if (raw === 'true') add.push(spec.label)
      else if (raw && raw !== 'false') errors.push(`'${flag}' takes true or false, got: ${raw}`)
    }
    return { add: [...new Set(add)], errors }
  }

  const axisPrefixes = Object.keys(ssot.axes).map((axis) => axis + '/')
  const managed = (name) =>
    knownLabels.has(name) || axisPrefixes.some((prefix) => name.startsWith(prefix))

  function reconciliationPlan(current, targetLabels) {
    const target = new Set(targetLabels)
    return {
      toRemove: current.filter((label) => managed(label) && !target.has(label)),
      toAdd: [...target].filter((label) => !current.includes(label)),
    }
  }

  return {
    knownLabels,
    orderedValues,
    severityOrderErrors,
    parseDeclaration,
    resolve,
    managed,
    reconciliationPlan,
  }
}

module.exports = { createIssueTaxonomyCore }
