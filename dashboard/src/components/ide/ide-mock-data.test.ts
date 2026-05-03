import { describe, expect, it } from 'vitest'
import { createAnchoredThreadRailStore } from './anchored-thread-rail-store'
import {
  IDE_MOCK_ANNOTATIONS,
  IDE_MOCK_FILE_PATH,
  IDE_MOCK_RELATED_LINE,
  IDE_MOCK_SOURCE,
  IDE_MOCK_THREADS,
  ideMockAnnotationsForLayer,
  ideMockAnnotationsForLine,
} from './ide-mock-data'

describe('IDE mock data', () => {
  it('keeps annotation anchors inside the editor source document', () => {
    const lineCount = IDE_MOCK_SOURCE.split('\n').length

    expect(IDE_MOCK_THREADS).toEqual(IDE_MOCK_ANNOTATIONS.map(annotation => annotation.thread))
    for (const annotation of IDE_MOCK_ANNOTATIONS) {
      const { anchor } = annotation.thread
      expect(anchor.file_path).toBe(IDE_MOCK_FILE_PATH)
      if (anchor.line_start === null || anchor.line_end === null) {
        throw new Error(`annotation ${annotation.thread.id} must be line anchored`)
      }
      expect(anchor.line_start).toBeGreaterThanOrEqual(1)
      expect(anchor.line_end).toBeLessThanOrEqual(lineCount)
    }
  })

  it('drives editor layer lookup and rail line lookup from the same anchors', () => {
    const railStore = createAnchoredThreadRailStore(IDE_MOCK_FILE_PATH)
    railStore.seed(IDE_MOCK_THREADS)

    expect(ideMockAnnotationsForLine(IDE_MOCK_RELATED_LINE).map(annotation => annotation.thread.id))
      .toEqual(railStore.threadsForLine(IDE_MOCK_RELATED_LINE).map(thread => thread.id))
    expect(ideMockAnnotationsForLayer('tools').map(annotation => annotation.thread.id))
      .toContain('thread-normalize-tool-choice')
  })
})
