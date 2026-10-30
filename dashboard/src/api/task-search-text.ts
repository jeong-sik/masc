import { get } from './core'

export interface TaskSearchDocument {
  id: string
  description: string
  description_revision: string
}

export async function fetchTaskSearchText(): Promise<Map<string, TaskSearchDocument>> {
  const response = await get<unknown>('/api/v1/dashboard/tasks/search-text')
  if (!response || typeof response !== 'object' || !('tasks' in response) || !Array.isArray(response.tasks)) {
    throw new Error('Invalid task search response')
  }
  const documents = new Map<string, TaskSearchDocument>()
  for (const row of response.tasks) {
    if (!row || typeof row !== 'object' || typeof row.id !== 'string' || !row.id
      || typeof row.description !== 'string' || typeof row.description_revision !== 'string'
      || !/^[0-9a-f]{64}$/.test(row.description_revision) || documents.has(row.id)) {
      throw new Error('Invalid task search document')
    }
    documents.set(row.id, row)
  }
  return documents
}
