import { isRecord } from '../components/common/normalize'
import { post } from './core'
import { ensureDevToken } from './dev-token'
import {
  parseKeeperSecretProjection,
  type KeeperSecretProjection,
} from './schemas/keeper-composite'

export type KeeperSecretScope = 'shared' | 'keeper'

export interface KeeperSecretEnvMutation {
  scope: KeeperSecretScope
  name: string
}

export interface KeeperSecretEnvSetMutation extends KeeperSecretEnvMutation {
  value: string
}

export interface KeeperSecretFileMutation {
  scope: KeeperSecretScope
  path: string
}

export interface KeeperSecretFileSetMutation extends KeeperSecretFileMutation {
  value: string
}

function secretMutationPath(keeperName: string): string {
  return `/api/v1/keepers/${encodeURIComponent(keeperName)}/secrets`
}

function parseSecretMutationResponse(raw: unknown): KeeperSecretProjection {
  if (!isRecord(raw)) return parseKeeperSecretProjection(raw)
  return parseKeeperSecretProjection(raw.secret_projection)
}

export async function setKeeperSecretEnv(
  keeperName: string,
  mutation: KeeperSecretEnvSetMutation,
): Promise<KeeperSecretProjection> {
  await ensureDevToken()
  const raw = await post<unknown>(secretMutationPath(keeperName), {
    action: 'set_env',
    scope: mutation.scope,
    name: mutation.name,
    value: mutation.value,
  })
  return parseSecretMutationResponse(raw)
}

export async function deleteKeeperSecretEnv(
  keeperName: string,
  mutation: KeeperSecretEnvMutation,
): Promise<KeeperSecretProjection> {
  await ensureDevToken()
  const raw = await post<unknown>(secretMutationPath(keeperName), {
    action: 'delete_env',
    scope: mutation.scope,
    name: mutation.name,
  })
  return parseSecretMutationResponse(raw)
}

export async function setKeeperSecretFile(
  keeperName: string,
  mutation: KeeperSecretFileSetMutation,
): Promise<KeeperSecretProjection> {
  await ensureDevToken()
  const raw = await post<unknown>(secretMutationPath(keeperName), {
    action: 'set_file',
    scope: mutation.scope,
    path: mutation.path,
    value: mutation.value,
  })
  return parseSecretMutationResponse(raw)
}

export async function deleteKeeperSecretFile(
  keeperName: string,
  mutation: KeeperSecretFileMutation,
): Promise<KeeperSecretProjection> {
  await ensureDevToken()
  const raw = await post<unknown>(secretMutationPath(keeperName), {
    action: 'delete_file',
    scope: mutation.scope,
    path: mutation.path,
  })
  return parseSecretMutationResponse(raw)
}
