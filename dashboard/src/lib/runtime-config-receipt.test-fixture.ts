import type {
  CommittedRuntimeTomlConfig,
  CommittedRuntimeSkillApplication,
  RuntimeTomlConfig,
  RuntimeTomlEditorProtocol,
} from '../api/dashboard-runtime'

type RuntimeTomlEditorProtocolFixture = Omit<
  RuntimeTomlEditorProtocol,
  'provider_fields' | 'required_provider_fields'
> & {
  readonly provider_fields: readonly string[]
  readonly required_provider_fields: readonly string[]
}

type RuntimeTomlConfigFixtureInput = Omit<RuntimeTomlConfig, 'path' | 'provider_protocols'> & {
  path: string
  provider_protocols?: readonly RuntimeTomlEditorProtocolFixture[]
}

interface CommittedRuntimeTomlConfigFixtureOptions {
  readonly order?: string
  readonly durability?: CommittedRuntimeTomlConfig['commit']['durability']
  readonly skills?: CommittedRuntimeSkillApplication
  readonly routing?: CommittedRuntimeTomlConfig['application']['routing']
  readonly keeperOverlay?: CommittedRuntimeTomlConfig['application']['keeper_overlay']
}

const defaultRouting: CommittedRuntimeTomlConfig['application']['routing'] = {
  status: 'applied',
  requires_restart: false,
  applied_at: null,
}

const defaultKeeperOverlay: CommittedRuntimeTomlConfig['application']['keeper_overlay'] = {
  status: 'not_configured',
  requires_restart: false,
  applied_at: null,
  configured_count: 0,
  pending_keys: [],
  applied_keys: [],
  preempted_keys: [],
}

export function committedRuntimeTomlConfigFixture(
  config: RuntimeTomlConfigFixtureInput,
  options: CommittedRuntimeTomlConfigFixtureOptions = {},
): CommittedRuntimeTomlConfig {
  const sourceRevision = 'runtime-source-revision'
  const application = config.application
  const skills = options.skills ?? {
    state: 'published',
    input_source_revision: sourceRevision,
    snapshot_revision: 'skill-snapshot-revision',
    catalog_revision: 'skill-catalog-revision',
    config_state: 'configured',
  }

  return {
    ...config,
    ok: true,
    provider_protocols: (config.provider_protocols ?? []).map(protocol => ({
      ...protocol,
      provider_fields: [...protocol.provider_fields],
      required_provider_fields: [...protocol.required_provider_fields],
    })),
    state: 'committed',
    commit: {
      source_revision: sourceRevision,
      order: options.order ?? '7',
      durability: options.durability ?? 'durable',
    },
    application: {
      operation: application?.operation ?? 'test_write',
      routing: options.routing ?? defaultRouting,
      keeper_overlay: options.keeperOverlay ?? defaultKeeperOverlay,
      skills,
    },
  }
}
