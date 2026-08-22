// Sub-views the parity harness can reach.
//
// The prototype deep-links only `?surface=` and `?keeper=`, so everything behind
// a section tab or a drawer — Lane Queue, the prompt book, every Settings pane —
// is reachable by clicking and nothing else. Measuring only the deep-linkable
// surfaces leaves most of the design unverified: Monitor alone has seven
// sections and Settings twelve, and `?surface=settings` is rejected outright
// because Settings is not in the prototype's SURFACES registry.
//
// A view is a surface plus the clicks that open it. Selectors are the
// prototype's own, and the live parity page renders the same DOM, so one recipe
// drives both sides.

const monitorSection = (n, id) => ({
  id: `monitor-${id}`,
  surface: 'monitor',
  clicks: [`.fl-sec:nth-of-type(${n})`],
})

// `.set-nav-item` buttons are split across SET_GROUPS, so `nth-of-type` counts
// within a group, not across the rail. Playwright's `nth=` is flat, and 0-based.
const settingsSection = (n, id) => ({
  id: `settings-${id}`,
  surface: 'keepers',
  clicks: ['.nav-item[title="설정"]', `.set-nav-item >> nth=${n - 1}`],
})

export const VIEWS = [
  // Monitor — tab 1 (Keeper 목록) is what `?surface=monitor` already lands on.
  monitorSection(2, 'internal'),
  monitorSection(3, 'lanes'),
  monitorSection(4, 'journey'),
  monitorSection(5, 'tools'),
  monitorSection(6, 'runtime'),
  monitorSection(7, 'observatory'),

  // Settings — no deep link at all; the rail footer is the only way in.
  settingsSection(1, 'account'),
  settingsSection(2, 'runtime'),
  settingsSection(3, 'runtimes'),
  settingsSection(4, 'routing'),
  settingsSection(5, 'mcp'),
  settingsSection(6, 'prompts'),
  settingsSection(7, 'fusion'),
  settingsSection(8, 'repositories'),
  settingsSection(9, 'paths'),
  settingsSection(10, 'logs'),
  settingsSection(11, 'notify'),
  settingsSection(12, 'display'),

  // Toggles inside a surface that swap the whole body.
  { id: 'schedule-list', surface: 'schedule', clicks: ['.sch-viewbtn:nth-of-type(2)'] },
  { id: 'approvals-history', surface: 'approvals', clicks: ['.ap-viewbtn:nth-of-type(2)'] },
  { id: 'ide-annotations', surface: 'ide', clicks: ['.ide-rail-tab:nth-of-type(2)'] },
  { id: 'ide-cursor', surface: 'ide', clicks: ['.ide-rail-tab:nth-of-type(3)'] },
]

export const VIEW_BY_ID = new Map(VIEWS.map((v) => [v.id, v]))
