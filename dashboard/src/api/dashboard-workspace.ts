import type { Message } from '../types'
import { isRecord } from '../lib/type-guards'
import { get, type AbortableRequestOptions } from './core'

function requiredString(
  record: Record<string, unknown>,
  field: string,
  index: number,
): string {
  const value = record[field]
  if (typeof value !== 'string') {
    throw new Error(`Workspace message ${index}.${field} must be a string`)
  }
  return value
}

function decodeDashboardWorkspaceMessage(raw: unknown, index: number): Message {
  if (!isRecord(raw)) {
    throw new Error(`Workspace message ${index} must be an object`)
  }
  return {
    id: requiredString(raw, 'id', index),
    from: requiredString(raw, 'sender', index),
    content: requiredString(raw, 'body', index),
    timestamp: requiredString(raw, 'ts', index),
    type: requiredString(raw, 'type', index),
    workspace: requiredString(raw, 'workspace_id', index),
    mentions: requiredStringArray(raw, 'mentions', index),
  }
}

function requiredStringArray(
  record: Record<string, unknown>,
  field: string,
  index: number,
): string[] {
  const value = record[field]
  if (!Array.isArray(value) || !value.every(item => typeof item === 'string')) {
    throw new Error(`Workspace message ${index}.${field} must be a string array`)
  }
  return value
}

export async function fetchDashboardWorkspaceMessages(
  opts?: AbortableRequestOptions,
): Promise<Message[]> {
  const response = await get<unknown>('/api/v1/dashboard/workspace', {
    signal: opts?.signal,
  })
  if (!isRecord(response) || !Array.isArray(response.messages)) {
    throw new Error('Workspace messages response must contain a messages array')
  }
  return response.messages.map(decodeDashboardWorkspaceMessage)
}
