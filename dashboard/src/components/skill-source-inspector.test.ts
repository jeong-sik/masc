// @vitest-environment happy-dom
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { h, render } from 'preact'
import { act } from 'preact/test-utils'
import { SkillSourceInspector } from './skill-source-inspector'
import { readSkillSource, type SkillEditorLoaded, type SkillReference } from '../api/dashboard-skills'

vi.mock('../api/dashboard-skills', () => ({ readSkillSource: vi.fn() }))
const reference: SkillReference = { identity: { source_id: 'local', package_id: 'pack', name: 'research' }, content_revision: 'revision-one' }
const source = '---\nname: research\n---\n# Exact instructions\nCompare sources.\n<script>literal text</script>\n'
const loaded = (ref = reference): SkillEditorLoaded => ({ status: 'ready', reference: ref, snapshot_revision: 'snapshot-one', source_text: source, access: 'read_only' })
let container: HTMLDivElement
beforeEach(() => { vi.resetAllMocks(); container = document.createElement('div'); document.body.append(container) })
afterEach(() => { render(null, container); container.remove() })
async function mount(ref = reference) { await act(async () => { render(h(SkillSourceInspector, { reference: ref }), container) }) }

describe('SkillSourceInspector', () => {
  it('loads and shows exact read-only source on entry without another click', async () => {
    vi.mocked(readSkillSource).mockResolvedValue(loaded())
    await mount()
    expect(readSkillSource).toHaveBeenCalledWith(reference)
    expect(container.querySelector('pre')?.textContent).toBe(source)
    expect(container.querySelector('pre')?.getAttribute('tabindex')).toBe('0')
    expect(container.querySelector('script')).toBeNull()
    expect(container.querySelector('textarea')).toBeNull()
    expect(container.textContent).toContain('revision-one')
    expect(container.textContent).toContain('read_only')
  })
  it('shows failure and retries the same source without inventing content', async () => {
    vi.mocked(readSkillSource).mockRejectedValueOnce(new Error('Source revision no longer available')).mockResolvedValueOnce(loaded())
    await mount()
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('Source revision no longer available')
    expect(container.querySelector('pre')).toBeNull()
    await act(async () => { container.querySelector('button')!.click() })
    await act(async () => { await Promise.resolve() })
    expect(readSkillSource).toHaveBeenCalledTimes(2)
    expect(container.querySelector('pre')?.textContent).toBe(source)
  })
  it('ignores a late response after the selected revision changes', async () => {
    let resolveFirst!: (value: SkillEditorLoaded) => void
    vi.mocked(readSkillSource).mockReturnValueOnce(new Promise(resolve => { resolveFirst = resolve })).mockResolvedValueOnce(loaded({ ...reference, content_revision: 'revision-two' }))
    await mount()
    await mount({ ...reference, content_revision: 'revision-two' })
    await act(async () => { resolveFirst(loaded()) })
    expect(container.textContent).toContain('revision-two')
    expect(container.textContent).not.toContain('revision-one')
  })
  it('refuses source returned for a different revision', async () => {
    vi.mocked(readSkillSource).mockResolvedValue(loaded({ ...reference, content_revision: 'wrong' }))
    await mount()
    expect(container.querySelector('[role="alert"]')?.textContent).toContain('does not match')
    expect(container.querySelector('pre')).toBeNull()
  })
})
