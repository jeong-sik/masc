import {
  array,
  boolean,
  literal,
  nullable,
  number,
  object,
  optional,
  picklist,
  string,
  type BaseIssue,
  type InferOutput,
} from 'valibot'

import { SchemaDriftError, parseOrThrow } from './drift-error'

export const KeeperSandboxProfileSchema = picklist(['local', 'docker'])
export const KeeperSandboxNetworkModeSchema = picklist(['none', 'host'])

const KeeperSandboxEffectiveModeSchema = picklist([
  'local',
  'docker_idle',
  'docker_active',
  'docker_listing_failed',
])

const KeeperSandboxSecurityBoundarySchema = object({
  execution_boundary: picklist(['host_process', 'docker_container']),
  filesystem_boundary: picklist(['host_filesystem_tool_policy', 'explicit_container_mounts']),
  network_boundary: picklist(['host_network_namespace', 'isolated_network_namespace']),
  credential_boundary: picklist(['managed_home_projection', 'ephemeral_container_projection']),
  rootfs_read_only: nullable(boolean()),
  cap_drop_all: nullable(boolean()),
  no_new_privileges: nullable(boolean()),
})

const KeeperSandboxContainerKindSchema = picklist(['oneshot', 'turn'])

const KeeperSandboxContainerSchema = object({
  id: string(),
  name: string(),
  image: string(),
  status: string(),
  running: nullable(boolean()),
  created_at: nullable(string()),
  keeper_name: nullable(string()),
  container_kind: nullable(KeeperSandboxContainerKindSchema),
  network_label: nullable(KeeperSandboxNetworkModeSchema),
  owner_pid: nullable(number()),
  started_at: nullable(number()),
  ttl_sec: nullable(number()),
})

const KeeperSandboxRequiredCommandSchema = object({
  command: string(),
  available: boolean(),
})

const KeeperSandboxPreflightSchema = object({
  backend: literal('docker'),
  status: picklist(['ok', 'error']),
  ok: boolean(),
  image: string(),
  docker_runtime_ok: boolean(),
  docker_runtime_error: nullable(string()),
  hardening_ok: boolean(),
  hardening_error: nullable(string()),
  image_present: boolean(),
  image_error: nullable(string()),
  failure_classes: array(string()),
  required_commands: array(KeeperSandboxRequiredCommandSchema),
  missing_commands: array(string()),
  next_actions: array(string()),
})

const KeeperSandboxIdentitySchema = object({
  agent_name: string(),
  expected_agent_name: string(),
  agent_name_matches: boolean(),
  trace_id: string(),
  warnings: array(string()),
})

const KeeperPlaygroundRepoPolicyStatusSchema = picklist([
  'allowed',
  'unregistered_repository',
  'mapping_load_error',
  'repository_identity_mismatch',
  'repository_store_error',
])

const KeeperPlaygroundRepoSchema = object({
  name: string(),
  source: picklist(['git', 'cache', 'filesystem']),
  path: string(),
  policy_status: KeeperPlaygroundRepoPolicyStatusSchema,
  policy_allowed: boolean(),
  policy_source: string(),
  policy_reason: nullable(string()),
  error: nullable(string()),
  branch: optional(string()),
  latest_commit: optional(string()),
  shallow: optional(boolean()),
  observed_at: optional(string()),
  observed_at_unix: optional(number()),
})

export const KeeperSandboxStatusSchema = object({
  keeper: string(),
  sandbox_profile: KeeperSandboxProfileSchema,
  configured_network_mode: KeeperSandboxNetworkModeSchema,
  effective_mode: KeeperSandboxEffectiveModeSchema,
  security_boundary: KeeperSandboxSecurityBoundarySchema,
  container_count: number(),
  containers: array(KeeperSandboxContainerSchema),
  preflight: nullable(KeeperSandboxPreflightSchema),
  container_error: nullable(string()),
  why_no_container: nullable(string()),
  recommendation: nullable(string()),
  playground_repos: array(KeeperPlaygroundRepoSchema),
  playground_repos_source: picklist(['live', 'skipped_dashboard_hot_path']),
  playground_repos_error: nullable(string()),
  identity: KeeperSandboxIdentitySchema,
})

const KeeperSandboxStatusResponseSchema = object({
  keeper: string(),
  sandbox: KeeperSandboxStatusSchema,
})

export type KeeperSandboxProfile = InferOutput<typeof KeeperSandboxProfileSchema>
export type KeeperSandboxNetworkMode = InferOutput<typeof KeeperSandboxNetworkModeSchema>
export type KeeperSandboxEffectiveMode = InferOutput<typeof KeeperSandboxEffectiveModeSchema>
export type KeeperSandboxSecurityBoundary = InferOutput<typeof KeeperSandboxSecurityBoundarySchema>
export type KeeperSandboxContainer = InferOutput<typeof KeeperSandboxContainerSchema>
export type KeeperSandboxPreflight = InferOutput<typeof KeeperSandboxPreflightSchema>
export type KeeperPlaygroundRepo = InferOutput<typeof KeeperPlaygroundRepoSchema>
export type KeeperSandboxStatus = InferOutput<typeof KeeperSandboxStatusSchema>
export type KeeperSandboxStatusResponse = InferOutput<typeof KeeperSandboxStatusResponseSchema>

export class KeeperSandboxSchemaDriftError extends SchemaDriftError {
  constructor(issues: readonly BaseIssue<unknown>[]) {
    super('keeper sandbox', issues)
  }
}

export function parseKeeperSandboxProfile(data: unknown): KeeperSandboxProfile {
  return parseOrThrow(KeeperSandboxSchemaDriftError, KeeperSandboxProfileSchema, data)
}

export function parseKeeperSandboxNetworkMode(data: unknown): KeeperSandboxNetworkMode {
  return parseOrThrow(KeeperSandboxSchemaDriftError, KeeperSandboxNetworkModeSchema, data)
}

export function parseKeeperSandboxStatusResponse(data: unknown): KeeperSandboxStatusResponse {
  return parseOrThrow(KeeperSandboxSchemaDriftError, KeeperSandboxStatusResponseSchema, data)
}
