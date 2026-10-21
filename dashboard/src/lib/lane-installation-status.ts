import type { LaneAddonInstance, LaneAddonSnapshot } from '../api/lane-addons'

export type LaneDeclaration = NonNullable<LaneAddonSnapshot['configuration']>['declarations'][number]
export type InstallationStatus =
  | 'unverified' | 'attention' | 'off' | 'stopping' | 'pending' | 'updating'
  | 'unavailable' | 'attached' | 'observing'
export type InstallationReading = {
  declaration: LaneDeclaration; worker: LaneAddonInstance | null;
  status: InstallationStatus; issues: readonly string[]; canObserve: boolean;
}

/** A retained worker is current only when the declaration and its ownership agree. */
export function installationReadings(snapshot: LaneAddonSnapshot): InstallationReading[] {
  const configuration = snapshot.configuration
  if (configuration === null) return []
  return configuration.declarations.map(declaration => {
    const candidates = snapshot.instances.filter(worker => worker.runtime_presence === 'live'
      && worker.instance_id === declaration.instance_id
      && worker.configuration?.id === declaration.id
      && worker.configuration.source_path === declaration.source_path
      && worker.configuration.revision === declaration.applied_revision)
    const worker = candidates.length === 1 ? candidates[0]! : null
    const application = declaration.application
    const issues = configuration.issues.filter(issue => issue.source_path === declaration.source_path
      || issue.source_path === configuration.directory || issue.id === declaration.id)
      .map(issue => issue.message)
    if (application?.kind === 'unknown' || application?.kind === 'failed') issues.push(...application.messages)
    const duplicate = configuration.declarations.some(other => other !== declaration
      && (other.id === declaration.id || other.source_path === declaration.source_path))
    let status: InstallationStatus
    if (!configuration.complete || !application || application.kind === 'unknown') status = 'unverified'
    else if (duplicate || issues.length > 0 || application.kind === 'failed') status = 'attention'
    else switch (application.kind) {
      case 'inactive': status = declaration.enabled ? 'unverified' : 'off'; break
      case 'cleaning': status = 'stopping'; break
      case 'starting': status = declaration.applied_revision === null ? 'pending' : 'updating'; break
      case 'applied':
        if (!declaration.enabled || declaration.applied_revision !== declaration.desired_revision) status = 'unverified'
        else if (!worker || application.instance_id !== worker.instance_id || worker.phase.kind === 'detached') status = 'unavailable'
        else if (worker.phase.kind === 'failed') status = 'attention'
        else if (worker.phase.kind === 'detaching') status = 'stopping'
        else status = worker.phase.kind
        break
    }
    return { declaration, worker, status,
      issues: duplicate ? [...issues, 'Installation ID or source path is ambiguous in this reading.'] : issues,
      canObserve: status === 'attached' }
  })
}

export const installationStatusLabels: Record<InstallationStatus, string> = {
  unverified: 'Inventory incomplete', attention: 'Needs attention', off: 'Configured off',
  stopping: 'Worker cleanup pending', pending: 'Waiting for first application', updating: 'Update pending',
  unavailable: 'Current worker unavailable', attached: 'Worker attached', observing: 'Observing',
}
export type InstallationFilter = 'all' | 'attention' | 'pending' | 'off' | 'available'
export function matchesInstallation(reading: InstallationReading, query: string, filter: InstallationFilter): boolean {
  const group = filter === 'all'
    || filter === 'attention' && ['unverified', 'attention', 'unavailable'].includes(reading.status)
    || filter === 'pending' && ['stopping', 'pending', 'updating'].includes(reading.status)
    || filter === 'off' && reading.status === 'off'
    || filter === 'available' && ['attached', 'observing'].includes(reading.status)
  const terms = query.trim().toLocaleLowerCase().split(/\s+/u)
  const searchable = [reading.declaration.id, reading.declaration.source_path,
    reading.worker?.title, reading.worker?.addon_id, reading.worker?.run_id].filter(value => value !== undefined)
    .join(' ').toLocaleLowerCase()
  return group && terms.every(term => searchable.includes(term))
}
