import { html } from 'htm/preact'
import { route } from '../router'
import { Tools } from './tools/tools-main'
import { HarnessHealth } from './harness-health'
import { LabPerf } from './lab-perf'
import { KeeperMemoryHealth } from './memory/keeper-memory-health'
import { SectionNav } from './common/section-nav'
import { SurfaceHeader } from './common/surface-header'

type LabSection =
  | 'tools'
  | 'harness'
  | 'performance'
  | 'keeper-memory-health'

function currentSection(): LabSection {
  const section = route.value.params.section
  if (
    section === 'harness'
    || section === 'performance'
    || section === 'keeper-memory-health'
  ) {
    return section
  }
  return 'tools'
}

export function Lab() {
  const section = currentSection()

  return html`
    <div class="v2-lab-surface ss-surface bg-surface-page flex flex-col gap-6" data-testid="lab-surface">
      <${SectionNav} tab="lab" current=${section} />
      <${SurfaceHeader} />
      ${section === 'tools' ? html`
        <${Tools} />
      ` : null}

      ${section === 'harness' ? html`
        <${HarnessHealth} />
      ` : null}

      ${section === 'performance' ? html`
        <${LabPerf} />
      ` : null}

      ${section === 'keeper-memory-health' ? html`
        <${KeeperMemoryHealth} />
      ` : null}
    </div>
  `
}
