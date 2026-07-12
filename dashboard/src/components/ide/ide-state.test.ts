import { beforeEach, describe, expect, it } from 'vitest'
import {
  activeIdeFile,
  activeIdeFocus,
  focusIdeContextAnchor,
  focusIdeFile,
  ideContextFocus,
  synchronizeIdeWorkspaceIdentity,
} from './ide-state'

describe('ide-state', () => {
  beforeEach(() => {
    synchronizeIdeWorkspaceIdentity({ kind: 'project' })
    focusIdeFile({
      path: 'package.json',
      origin: 'operator',
      availability: 'available',
    })
    ideContextFocus.value = null
  })

  it('normalizes backslash paths before focusing context anchors', () => {
    focusIdeContextAnchor({
      file_path: 'src\\runtime\\router.ts',
      line: 12,
      surface: 'Log',
      label: 'runtime event',
      source_id: 'evt-1',
    }, 'operator')

    expect(activeIdeFile.value).toBe('src/runtime/router.ts')
    expect(ideContextFocus.value).toMatchObject({
      file_path: 'src/runtime/router.ts',
      line: 12,
      source_id: 'evt-1',
    })
    expect(activeIdeFocus.value).toEqual({
      path: 'src/runtime/router.ts',
      origin: 'operator',
      workspace_identity: { kind: 'project' },
      availability: 'pending',
    })
  })

  it.each([
    '/absolute/path.ts',
    'C:/repo/src/runtime.ts',
    'D:\\repo\\src\\runtime.ts',
    'src/../runtime.ts',
    './runtime.ts',
    'src//runtime.ts',
  ])('rejects unsafe context anchor path %s', filePath => {
    focusIdeContextAnchor({
      file_path: filePath,
      line: 12,
      surface: 'Log',
      label: 'runtime event',
      source_id: 'evt-1',
    }, 'route')

    expect(activeIdeFile.value).toBe('package.json')
    expect(ideContextFocus.value).toBeNull()
  })

  it.each([0, -1, Number.NaN])('drops invalid context anchor line %s', line => {
    focusIdeContextAnchor({
      file_path: 'src/runtime/router.ts',
      line,
      surface: 'Log',
      label: 'runtime event',
      source_id: 'evt-1',
    }, 'operator')

    expect(activeIdeFile.value).toBe('src/runtime/router.ts')
    expect(ideContextFocus.value?.line).toBeUndefined()
  })
})
