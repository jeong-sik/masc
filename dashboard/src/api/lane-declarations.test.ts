import { afterEach, describe, expect, it, vi } from 'vitest'
import { ApiRequestError } from './core'
import { fetchLaneDeclaration, saveLaneDeclaration, LaneDeclarationError } from './lane-declarations'
const transport = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn() }))
vi.mock('./core', async original => ({ ...await original<typeof import('./core')>(), ...transport }))
const document = {
  file_name: 'layer.toml', source_path: '/workspace/config/lane-addons/layer.toml',
  source_text: '# unchanged raw text\n', source_revision: 'raw-sha', desired_revision: null,
  validation: { valid: false, messages: ['Required id is missing'] },
}
const receipt = { document, write: { state: 'created', durability: 'durable', detail: null }, application: 'pending_reconciliation' }
afterEach(() => vi.resetAllMocks())
describe('Lane declaration transport contract', () => {
  it('reads malformed raw text without inventing a parsed declaration revision', async () => {
    transport.get.mockResolvedValue(document)
    expect(await fetchLaneDeclaration(document.source_path)).toEqual(document)
    expect(transport.get).toHaveBeenCalledWith('/api/v1/lane-addons/declaration?source_path=%2Fworkspace%2Fconfig%2Flane-addons%2Flayer.toml', { signal: undefined })
  })
  it('uses explicit create and save modes with a raw source revision only for save', async () => {
    transport.post.mockResolvedValue(receipt)
    await saveLaneDeclaration({ mode: 'create', file_name: document.file_name, source_text: document.source_text })
    expect(transport.post).toHaveBeenLastCalledWith('/api/v1/lane-addons/declaration', { mode: 'create', file_name: 'layer.toml', source_text: '# unchanged raw text\n' })
    await saveLaneDeclaration({ mode: 'save', file_name: document.file_name, source_text: document.source_text, expected_source_revision: 'raw-sha' })
    expect(transport.post).toHaveBeenLastCalledWith('/api/v1/lane-addons/declaration', { mode: 'save', file_name: 'layer.toml', source_text: '# unchanged raw text\n', expected_source_revision: 'raw-sha' })
  })
  it('preserves a typed conflict document from the HTTP409 response', async () => {
    const body = { error: 'File changed', code: 'revision_conflict', current: document }
    transport.post.mockRejectedValue(new ApiRequestError({ method: 'POST', path: '/api/v1/lane-addons/declaration', status: 409, responseData: body }))
    const result = saveLaneDeclaration({ mode: 'save', file_name: document.file_name, source_text: 'new', expected_source_revision: 'older-sha' })
    await expect(result).rejects.toBeInstanceOf(LaneDeclarationError)
    await expect(result).rejects.toMatchObject({ failure: body })
  })
  it('rejects a receipt for a different file or text and unknown application states', async () => {
    const request = { mode: 'create' as const, file_name: document.file_name, source_text: document.source_text }
    for (const bad of [
      { ...receipt, document: { ...document, file_name: 'other.toml' } },
      { ...receipt, document: { ...document, source_text: 'rewritten' } },
      { ...receipt, application: 'applied' },
    ]) {
      transport.post.mockResolvedValue(bad)
      await expect(saveLaneDeclaration(request)).rejects.toThrow()
    }
  })
  it('never offers another file as the conflict save base', async () => {
    transport.post.mockRejectedValue(new ApiRequestError({ method: 'POST', path: '/api/v1/lane-addons/declaration', status: 409,
      responseData: { error: 'Conflict', code: 'revision_conflict', current: { ...document, file_name: 'different.toml' } } }))
    await expect(saveLaneDeclaration({ mode: 'create', file_name: 'layer.toml', source_text: 'new' })).rejects.toThrow('does not match the submitted TOML file')
    transport.get.mockResolvedValue({ ...document, source_path: '/different/layer.toml' })
    await expect(fetchLaneDeclaration(document.source_path)).rejects.toThrow('does not match the requested path')
  })
})
