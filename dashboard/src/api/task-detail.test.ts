import { beforeEach, describe, expect, it, vi } from 'vitest'
vi.mock('./core', async importOriginal => ({
  ...await importOriginal<typeof import('./core')>(),
  get: vi.fn(),
}))
import { get } from './core'
import { fetchTaskDetail } from './actions'
import { normalizeTask } from '../store-normalizers'

beforeEach(() => { vi.mocked(get).mockReset() })
describe('complete task detail decoding', () => {
  it('retains a full description and contract with an encoded task id', async () => {
    const task = { id: 'task a', title: 'Task', description: '    code\n' + 'long '.repeat(10000),
      contract: { completion_contract: ['criterion'], required_evidence: ['proof'] } }
    vi.mocked(get).mockResolvedValue({ task })
    const result = await fetchTaskDetail(task.id)
    expect(get).toHaveBeenCalledWith('/api/v1/dashboard/tasks/detail?task_id=task+a')
    expect(result.description).toBe(task.description)
    expect(result.contract?.required_evidence).toEqual(['proof'])
    expect(result.detail_level).toBe('full')
  })
  it('accepts an explicitly empty full description', async () => {
    vi.mocked(get).mockResolvedValue({ task: { id: 'a', title: 'A', description: '' } })
    expect((await fetchTaskDetail('a')).description).toBe('')
  })
  it.each([
    null,
    {},
    { task: { id: 'wrong', title: 'Wrong', description: '' } },
    { task: { id: 'a', title: 'No details' } },
    { task: { id: 'a', title: 'Summary', description: 'preview', detail_level: 'summary' } },
  ])('rejects malformed or incomplete details: %j', async response => {
    vi.mocked(get).mockResolvedValue(response)
    await expect(fetchTaskDetail('a')).rejects.toThrow('complete requested task')
  })
  it('preserves summary state and rejects unknown detail states', () => {
    expect(normalizeTask({ id: 'a', title: 'A', detail_level: 'summary' })?.detail_level).toBe('summary')
    expect(normalizeTask({ id: 'a', title: 'A', detail_level: 'maybe' })).toBeNull()
  })
})
