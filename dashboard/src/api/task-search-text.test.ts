import { describe, expect, it, vi, beforeEach } from 'vitest'
import { get } from './core'
import { fetchTaskSearchText } from './task-search-text'
vi.mock('./core', () => ({ get: vi.fn() }))
const row = { id: 'one', description: '  body\n끝단 Σİß  ', description_revision: 'a'.repeat(64) }
beforeEach(() => vi.mocked(get).mockReset())
describe('task search text API', () => {
  it('preserves exact description bytes and revision', async () => {
    vi.mocked(get).mockResolvedValue({ tasks: [row] })
    const result = await fetchTaskSearchText()
    expect(get).toHaveBeenCalledWith('/api/v1/dashboard/tasks/search-text')
    expect(result.get('one')).toEqual(row)
  })
  it.each([null, {}, { tasks: null }, { tasks: [null] },
    { tasks: [{ ...row, description: null }] },
    { tasks: [{ ...row, description_revision: 'bad' }] },
    { tasks: [{ ...row, id: '' }] }, { tasks: [row, row] }])('rejects incomplete or ambiguous responses: %j', async response => {
    vi.mocked(get).mockResolvedValue(response)
    await expect(fetchTaskSearchText()).rejects.toThrow()
  })
})
