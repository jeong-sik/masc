import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
let sequence = 0
/** Component fixtures using real shared resources need a confirmed workspace. */
export function confirmRuntimeTestWorkspace() {
  const epoch = `runtime-consumer-fixture-${++sequence}`
  invalidateExecutionSnapshotGeneration(epoch, 0)
  hydrateExecutionSnapshot({ execution_publication_epoch: epoch, execution_publication_generation: 1,
    status: { project: 'fixture', workspace_root: '/fixture/runtime-consumer' },
  } as Parameters<typeof hydrateExecutionSnapshot>[0])
}
