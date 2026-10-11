// @vitest-environment happy-dom
import { afterEach, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
const mocks = vi.hoisted(() => ({ load: vi.fn() }))
vi.mock('./tool-executor-state', async () => {
 const { signal } = await import('@preact/signals')
 return {
  selectedTool: signal(null), formValues: signal({}), validationErrors: signal([]),
  executing: signal(false), lastResult: signal(null), schemasLoading: signal(false),
  schemasError: signal(null), selectedToolAccess: signal({ allowed: true }),
  loadToolSchemas: mocks.load, updateFormValues: vi.fn(), executeTool: vi.fn(), clearSelection: vi.fn(),
 }
})
vi.mock('./tool-picker', () => ({ ToolPicker: () => null }))
vi.mock('./schema-form', () => ({ SchemaForm: () => null }))
vi.mock('./tool-result-display', () => ({ ToolResultDisplay: () => null }))
import { setStoredToken } from '../../api/core'
import { ToolExecutor } from './tool-executor'
const root = document.createElement('div')
afterEach(() => { render(null, root); mocks.load.mockClear() })
it('reloads an already mounted executor when its credential changes', async () => {
 setStoredToken('synthetic-mounted-a')
 render(h(ToolExecutor, {}), root)
 await vi.waitFor(() => expect(mocks.load).toHaveBeenCalledTimes(1))
 setStoredToken('synthetic-mounted-b')
 await vi.waitFor(() => expect(mocks.load).toHaveBeenCalledTimes(2))
 render(null, root)
 setStoredToken('synthetic-unmounted-c')
 await new Promise(resolve => setTimeout(resolve, 0))
 expect(mocks.load).toHaveBeenCalledTimes(2)
})
