import { hydrateExecutionSnapshot, invalidateExecutionSnapshotGeneration } from '../store'
export const RUNTIME_TEST_OBSERVER_INSTANCE = 'runtime-observer-fixture'
let sequence = 0
/** Component fixtures using real shared resources need a confirmed workspace. */
export function confirmRuntimeTestWorkspace() {
  const epoch = `runtime-consumer-fixture-${++sequence}`
  invalidateExecutionSnapshotGeneration(epoch, 0)
  hydrateExecutionSnapshot({ observer_instance_id: RUNTIME_TEST_OBSERVER_INSTANCE, execution_publication_epoch: epoch, execution_publication_generation: 1,
    status: { project: 'fixture', workspace_root: '/fixture/runtime-consumer' },
  } as Parameters<typeof hydrateExecutionSnapshot>[0])
}
