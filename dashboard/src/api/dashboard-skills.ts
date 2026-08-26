// MASC Dashboard — Skills catalog REST client.
//
// Reads /api/v1/skills: the published workspace skill snapshot
// (masc.skill-snapshot/v1, lib/skill_snapshot) plus the optional exact
// parser-derived surface of each effective Skill.

import { get, type GetOptions } from './core'

export interface SkillIdentity {
  source_id: string
  package_id: string
  name: string
}

export interface SkillSnapshotEntry {
  identity: SkillIdentity
  content_revision: string
  description: string
  conformance: string
  diagnostics?: string[]
  body_bytes: number
}

export type SkillSnapshotConfig =
  | {
      kind: 'configured'
      revision: string
      resource_read_max_bytes: number | null
    }
  | { kind: 'rejected'; source_revision: string; diagnostics: string[] }
  | { kind: 'unreadable' }

export interface SkillSnapshot {
  snapshot_revision: string
  catalog_revision: string
  config: SkillSnapshotConfig
  skills: SkillSnapshotEntry[]
  effective_skills: SkillIdentity[]
  shadows: unknown[]
  rejections: unknown[]
}

export interface SkillReference {
  identity: SkillIdentity
  content_revision: string
}

export type SkillSurface =
  | { reference: SkillReference; kind: 'instruction'; diagnostics?: string[] }
  | ({
      reference: SkillReference
      kind: 'composition'
      tool_name: string
      execution: string
      diagnostics?: string[]
    })
  | { reference: SkillReference; kind: 'unavailable'; error: string }

export type SkillsResponse =
  | {
      schema: string
      state: 'ready'
      snapshot: SkillSnapshot
      surfaces?: SkillSurface[]
    }
  | { schema: string; state: 'not_registered' | 'uninitialized' | 'invalid_workspace' }

export async function fetchSkills(opts: GetOptions = {}): Promise<SkillsResponse> {
  return get<SkillsResponse>('/api/v1/skills', opts)
}
