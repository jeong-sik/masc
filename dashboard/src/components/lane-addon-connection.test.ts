import { html } from 'htm/preact'
import { cleanup, render } from '@testing-library/preact'
import { afterEach, describe, expect, it } from 'vitest'
import { parseLaneAddonSnapshot } from '../api/lane-addons'
import { LaneAddonConnection } from './lane-addon-connection'

const sourcePath = '/workspace/.masc/config/lane-addons/demo.toml'
const declaration = { id: 'demo', source_path: sourcePath, source_revision: 'file-2', enabled: false,
  desired_revision: 'inputs', applied_revision: null, instance_id: null, application: { kind: 'cleaning' } }
function snapshot(change: Record<string, unknown> = {}, complete = true) {
  return parseLaneAddonSnapshot({ configuration: { directory: '/workspace/.masc/config/lane-addons',
    complete, issues: [], declarations: [{ ...declaration, ...change }] }, instances: [], rows: [], coverage: [] })
}
afterEach(cleanup)
describe('host-owned Addon lifecycle observations', () => {
  it('does not turn a missing current worker ID into confirmed cleanup', () => {
    const screen = render(html`<${LaneAddonConnection} snapshot=${snapshot()} installationId="demo" sourcePath=${sourcePath} />`)
    expect(screen.getByRole('status').textContent).toBe('Worker cleanup pending')
  })
  it('does not turn a retained applied revision into a running worker', () => {
    const screen = render(html`<${LaneAddonConnection} snapshot=${snapshot({ enabled: true,
      applied_revision: 'inputs', instance_id: 'old', application: { kind: 'failed', messages: ['cleanup refused'] } })}
      installationId="demo" sourcePath=${sourcePath} />`)
    expect(screen.getByRole('status').textContent).toBe('Application failed · cleanup refused')
  })
  it('does not confirm a different current file or an incomplete inventory', () => {
    const screen = render(html`<${LaneAddonConnection} snapshot=${snapshot({ application: { kind: 'inactive' } })}
      installationId="demo" sourcePath=${sourcePath} expectedSourceRevision="file-3" />`)
    expect(screen.getByRole('status').textContent).toContain('this file’s application is not confirmed')
    screen.rerender(html`<${LaneAddonConnection} snapshot=${snapshot({ application: { kind: 'inactive' } }, false)}
      installationId="demo" sourcePath=${sourcePath} />`)
    expect(screen.getByRole('status').textContent).toContain('inventory is incomplete')
  })
  it.each([
    { application: undefined }, { source_revision: undefined },
    { enabled: false, application: { kind: 'applied', instance_id: 'old' } },
    { enabled: true, application: { kind: 'inactive' } },
    { application: { kind: 'unknown', messages: [] } },
    { application: { kind: 'new-unrecognized-state' } },
  ])('refuses missing or inconsistent host application facts: %j', change => {
    expect(() => snapshot(change)).toThrow()
  })
})
