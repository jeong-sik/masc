import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

function source(file: string): string {
  return readFileSync(resolve(__dirname, file), 'utf8')
}

function expectNoStaticParserImport(sourceText: string, parserName: string, schemaPath: string): void {
  expect(sourceText).not.toMatch(
    new RegExp(`import\\s*{[\\s\\S]*${parserName}[\\s\\S]*}\\s*from\\s*['"]${schemaPath}['"]`),
  )
}

describe('dashboard schema bundle boundary', () => {
  it('keeps Valibot dashboard schema parsers out of the initial dashboard API import', () => {
    const logs = source('dashboard-logs.ts')
    const agent = source('dashboard-agent.ts')
    const runtime = source('dashboard-runtime.ts')
    const barrel = source('dashboard.ts')

    expect(logs).toContain("await import('./schemas/logs')")
    expect(logs).toContain("await import('./schemas/provider-logs')")
    expect(logs).toContain("await import('./schemas/dashboard-config')")
    expectNoStaticParserImport(logs, 'parseLogsResponse', './schemas/logs')
    expectNoStaticParserImport(logs, 'parseProviderLogsCatalogResponse', './schemas/provider-logs')
    expectNoStaticParserImport(logs, 'parseProviderLogTailResponse', './schemas/provider-logs')
    expectNoStaticParserImport(logs, 'parseDashboardConfigResponse', './schemas/dashboard-config')

    expect(agent).toContain("await import('./schemas/agent-timeline')")
    expect(agent).toContain("await import('./schemas/agent-relations')")
    expectNoStaticParserImport(agent, 'parseAgentTimelineResponse', './schemas/agent-timeline')
    expectNoStaticParserImport(agent, 'parseAgentRelationsResponse', './schemas/agent-relations')

    expect(runtime).toContain("await import('./schemas/runtime-defaults')")
    expectNoStaticParserImport(runtime, 'parseRuntimeDefaultsResponse', './schemas/runtime-defaults')
    expect(runtime).toContain("await import('./schemas/runtime-resolved')")
    expectNoStaticParserImport(runtime, 'parseRuntimeResolvedResponse', './schemas/runtime-resolved')

    expect(barrel).not.toContain('SchemaDriftError')
  })
})
