import { html } from 'htm/preact'
import { cleanup, render, within } from '@testing-library/preact'
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
  const worker = (id: string, installation: string | null, path = sourcePath) => ({
    instance_id: id, incarnation: `${id}-incarnation`, run_id: 'same-run', addon_id: 'same-package',
    title: 'Same title', revision: 'package-revision', runtime_presence: 'retained', action_schema: null,
    package: { outputs: {}, binding_schema: null, presentation: { description: null, readings: [] } },
    configuration: installation === null ? null : { id: installation, source_path: path, revision: `${id}-binding` },
    phase: { kind: 'failed', message: 'cleanup refused' }, observation_seq: 2, rows_count: 3,
  })
  it('shows another installation at the exact TOML path separately from the current ID and unrelated workers', () => {
    const value = parseLaneAddonSnapshot({ ...snapshot(), instances: [
      worker('old', 'previous-installation'), worker('unrelated', 'other', '/another/demo.toml'),
      worker('current', 'demo'), worker('manual', null), worker('moved', 'demo', '/before/demo.toml'),
    ] })
    const screen = render(html`<${LaneAddonConnection} snapshot=${value} installationId="demo" sourcePath=${sourcePath} />`)
    const current = within(screen.getByLabelText('Workers with this installation ID'))
    expect(current.getByRole('article', { name: 'Worker current · incarnation current-incarnation' })).toBeTruthy()
    expect(current.getByRole('article', { name: 'Worker moved · incarnation moved-incarnation' })).toBeTruthy()
    expect(current.queryByRole('article', { name: 'Worker old · incarnation old-incarnation' })).toBeNull()
    const other = within(screen.getByLabelText('Other installation owners at this TOML path'))
    expect(other.getAllByRole('article')).toHaveLength(1)
    expect(other.getByText('Installation: previous-installation')).toBeTruthy()
    expect(other.getByText('Installed revision: old-binding')).toBeTruthy()
    expect(other.getByText('old · retained · failed · cleanup refused')).toBeTruthy()
    expect(screen.queryByRole('article', { name: 'Worker unrelated · incarnation unrelated-incarnation' })).toBeNull()
    expect(screen.queryByRole('article', { name: 'Worker manual · incarnation manual-incarnation' })).toBeNull()
    expect(screen.getByRole('status').textContent).toBe('Worker cleanup pending')
  })
  it('does not borrow another ID application when the selected declaration is absent', () => {
    const value = parseLaneAddonSnapshot({ ...snapshot({ enabled: true,
      application: { kind: 'applied', instance_id: 'old' } }), instances: [worker('old', 'demo')] })
    const screen = render(html`<${LaneAddonConnection} snapshot=${value} installationId="replacement" sourcePath=${sourcePath} />`)
    expect(screen.getByRole('status').textContent).toContain('no unique declaration')
    expect(within(screen.getByLabelText('Other installation owners at this TOML path'))
      .getByRole('article', { name: 'Worker old · incarnation old-incarnation' })).toBeTruthy()
    expect(within(screen.getByLabelText('Workers with this installation ID')).queryByRole('article')).toBeNull()
  })

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
