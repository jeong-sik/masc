// MASC Dashboard — Skills catalog REST client.
//
// Reads /api/v1/skills: the published workspace skill snapshot
// (masc.skill-snapshot/v1, lib/skill_snapshot) plus, beside it, how each
// effective skill parses for a keeper turn (kind, tool name) and how often
// it was used in the last `recent_window_rows` recorded tool calls. The
// envelope is frozen on the OCaml side (server_routes_http_routes_activity.ml)
// and this panel is its only consumer.

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
  body_bytes: number
}

export interface SkillSnapshot {
  snapshot_revision: string
  catalog_revision: string
  skills: SkillSnapshotEntry[]
  effective_skills: SkillIdentity[]
  shadows: unknown[]
  rejections: unknown[]
}

export type SkillUsage =
  | { name: string; directory: string; kind: 'instruction'; recent_use_count: number }
  | {
      name: string
      directory: string
      kind: 'composition'
      tool_name: string
      execution: string
      recent_use_count: number
    }
  | { name: string; directory: string; kind: 'unparsed'; error: string }

export type SkillsResponse =
  | {
      schema: string
      state: 'ready'
      snapshot: SkillSnapshot
      // Optional on the wire, not in the contract: the dashboard bundle ships
      // separately from the OCaml server (vite build -> dist), so a deploy can
      // put this panel in front of a server that predates the usage join. A
      // missing field must read as "not reported", never crash the panel.
      usage?: SkillUsage[]
      recent_window_rows?: number
    }
  | { schema: string; state: 'not_registered' | 'uninitialized' | 'invalid_workspace' }

export async function fetchSkills(opts: GetOptions = {}): Promise<SkillsResponse> {
  return get<SkillsResponse>('/api/v1/skills', opts)
}
