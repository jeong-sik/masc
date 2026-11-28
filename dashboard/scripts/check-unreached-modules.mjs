// Fails when a module under dashboard/src is not reachable from a production
// entry, or when production code reaches a test helper.
//
// The dashboard ships two bundles: index.html loads src/main.ts, and
// vite.accounts.config.ts builds src/accounts/index.html, which loads
// src/accounts/main.ts. TypeScript follows every import from those two files
// (value and type imports, re-exports, import() with a literal path). A module
// it does not reach runs on no screen, yet tsc and vitest keep compiling and
// passing it, so it stays green until someone edits it for a screen that is
// not there. #55162 and #55180 deleted 1,138 such files.
//
// Test helpers are the modules only tests import. They live in a directory
// named test-support or fixtures, or in a file named *.test-fixture.ts, and
// production code must not import them.

import { readdirSync } from 'node:fs'
import { dirname, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'

const dashboard = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const ENTRIES = ['src/main.ts', 'src/accounts/main.ts']
const TEST_SUPPORT_DIRECTORIES = new Set(['test-support', 'fixtures'])
const TEST_SUPPORT_SUFFIX = '.test-fixture.ts'

// Modules left unreached on purpose, each with what decides it: an issue that
// chooses between wiring the module in and deleting it, or an open PR that
// imports it from a live screen. The check fails when an entry becomes
// reachable or is deleted, so the entry leaves with its reason; the PR that
// wires a module in removes its line here.
const PENDING = new Map([
  ['src/schemas/sse_event_generated.ts', 'https://github.com/jeong-sik/masc/issues/55201 decides it'],
  ['src/api/published-artifact-checks.ts', 'kept as a dependency of the retained living-module tests in https://github.com/jeong-sik/masc/pull/55162'],
  ['src/components/common/happy-dom-helpers.ts', 'kept as a dependency of the retained living-module tests in https://github.com/jeong-sik/masc/pull/55162'],
  ['src/lib/nav-telemetry.ts', 'kept as a dependency of the retained living-module tests in https://github.com/jeong-sik/masc/pull/55162'],
  ['src/keeper-stream.ts', 'kept as a dependency of the retained living-module tests in https://github.com/jeong-sik/masc/pull/55162'],
  ['src/router.ts', 'kept as a dependency of the retained living-module tests in https://github.com/jeong-sik/masc/pull/55162'],
  ['src/keeper-message.ts', 'kept as a dependency of the retained living-module tests in https://github.com/jeong-sik/masc/pull/55162'],
  ['src/lib/keeper-reply-block-projection.ts', 'kept as a dependency of the retained living-module tests in https://github.com/jeong-sik/masc/pull/55162'],
  ['src/keeper-chat-operations-local.ts', 'kept as a dependency of the retained living-module tests in https://github.com/jeong-sik/masc/pull/55162'],
])

const fromDashboard = path => relative(dashboard, resolve(path)).split(sep).join('/')
const message = diagnostic => ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n')
const isChecked = path => path.endsWith('.ts') && !path.endsWith('.test.ts') && !path.endsWith('.d.ts')
const isTestSupport = path =>
  path.endsWith(TEST_SUPPORT_SUFFIX) || path.split('/').some(part => TEST_SUPPORT_DIRECTORIES.has(part))

const configFile = ts.readConfigFile(join(dashboard, 'tsconfig.json'), ts.sys.readFile)
if (configFile.error) {
  console.error(message(configFile.error))
  process.exit(1)
}
const config = ts.parseJsonConfigFileContent(configFile.config, ts.sys, dashboard)
if (config.errors.length > 0) {
  console.error(config.errors.map(message).join('\n'))
  process.exit(1)
}

const program = ts.createProgram({
  rootNames: ENTRIES.map(entry => join(dashboard, entry)),
  options: config.options,
})
const missingEntries = ENTRIES.filter(entry => program.getSourceFile(join(dashboard, entry)) === undefined)
if (missingEntries.length > 0) {
  console.error(`production entry not found: ${missingEntries.join(', ')}`)
  process.exit(1)
}

const reached = new Set(program.getSourceFiles().map(file => fromDashboard(file.fileName)))
const sources = readdirSync(join(dashboard, 'src'), { recursive: true, withFileTypes: true })
  .filter(entry => entry.isFile())
  .map(entry => fromDashboard(join(entry.parentPath, entry.name)))

const unreached = sources
  .filter(path => isChecked(path) && !isTestSupport(path) && !PENDING.has(path) && !reached.has(path))
  .sort()
const shippedHelpers = [...reached].filter(path => path.startsWith('src/') && isTestSupport(path)).sort()
const stalePending = [...PENDING].flatMap(([path, reason]) => {
  if (!sources.includes(path)) return [`  ${path} is gone; remove it from PENDING (${reason})`]
  if (reached.has(path)) return [`  ${path} is now reachable; remove it from PENDING (${reason})`]
  return []
})

const failures = []
if (unreached.length > 0) {
  failures.push(
    `${unreached.length} module(s) under src are not reachable from ${ENTRIES.join(' or ')}:`,
    ...unreached.map(path => `  ${path}`),
    'No screen runs them. Delete them with their tests, or import them from shipped code.',
    `A helper that only tests import belongs in a test-support or fixtures directory, or in a *${TEST_SUPPORT_SUFFIX} file.`,
  )
}
if (shippedHelpers.length > 0) {
  failures.push(
    `${shippedHelpers.length} test helper(s) are reachable from a production entry:`,
    ...shippedHelpers.map(path => `  ${path}`),
    'Production code must not import a test helper.',
  )
}
if (stalePending.length > 0) {
  failures.push('PENDING no longer matches the tree:', ...stalePending)
}
if (failures.length > 0) {
  console.error(failures.join('\n'))
  process.exit(1)
}

const reachedSources = [...reached].filter(path => path.startsWith('src/')).length
const helpers = sources.filter(path => isChecked(path) && isTestSupport(path)).length
console.log(
  [
    `${reachedSources} files under src are reachable from ${ENTRIES.join(' and ')}; ` +
      `${helpers} test helper module(s); ${PENDING.size} pending module(s):`,
    ...[...PENDING].map(([path, reason]) => `  ${path}: ${reason}`),
  ].join('\n'),
)
