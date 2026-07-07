import { describe, expect, it } from 'vitest'
import {
  MAX_FILE_SIZE,
  MAX_IMAGE_SIZE,
  stableAttachmentId,
  validateFile,
} from './attachments'

function fileOfSize(name: string, type: string, size: number): File {
  const file = new File(['x'], name, { type })
  Object.defineProperty(file, 'size', { value: size })
  return file
}

describe('validateFile', () => {
  it('accepts allowed image types within the size budget', () => {
    expect(validateFile(fileOfSize('a.png', 'image/png', 1024))).toBeNull()
    expect(validateFile(fileOfSize('a.webp', 'image/webp', MAX_IMAGE_SIZE))).toBeNull()
  })

  it('rejects unsupported image types', () => {
    expect(validateFile(fileOfSize('a.tiff', 'image/tiff', 1024))).toContain('지원하지 않는 이미지 형식')
  })

  it('rejects oversized images', () => {
    expect(validateFile(fileOfSize('a.png', 'image/png', MAX_IMAGE_SIZE + 1))).toContain('이미지 크기 초과')
  })

  it('accepts allowed text-like files within the size budget', () => {
    expect(validateFile(fileOfSize('a.md', 'text/markdown', MAX_FILE_SIZE))).toBeNull()
    expect(validateFile(fileOfSize('a.json', 'application/json', 10))).toBeNull()
  })

  it('accepts allowed audio files within the file size budget', () => {
    expect(validateFile(fileOfSize('clip.webm', 'audio/webm', MAX_FILE_SIZE))).toBeNull()
    expect(validateFile(fileOfSize('clip.wav', 'audio/wav', 10))).toBeNull()
  })

  it('rejects unsupported audio types', () => {
    expect(validateFile(fileOfSize('clip.aiff', 'audio/aiff', 10))).toContain('지원하지 않는 오디오 형식')
  })

  it('rejects oversized audio files', () => {
    expect(validateFile(fileOfSize('clip.webm', 'audio/webm', MAX_FILE_SIZE + 1))).toContain('오디오 크기 초과')
  })

  it('rejects unsupported file types', () => {
    expect(validateFile(fileOfSize('a.bin', 'application/octet-stream', 10))).toContain('지원하지 않는 파일 형식')
  })

  it('rejects oversized files', () => {
    expect(validateFile(fileOfSize('a.txt', 'text/plain', MAX_FILE_SIZE + 1))).toContain('파일 크기 초과')
  })
})

describe('stableAttachmentId', () => {
  it('derives a deterministic id from attachment identity and content', () => {
    const input = {
      name: 'trace.log',
      type: 'file',
      mimeType: 'text/plain',
      size: 12,
      data: 'data:text/plain;base64,QUJD',
    }

    expect(stableAttachmentId(input)).toBe(stableAttachmentId({ ...input }))
    expect(stableAttachmentId(input)).toMatch(/^att-[0-9a-z]+$/)
  })

  it('changes when the attachment content reference changes', () => {
    const base = {
      name: 'trace.log',
      type: 'file',
      mimeType: 'text/plain',
      size: 12,
    }

    expect(stableAttachmentId({ ...base, data: 'data:text/plain;base64,QUJD' }))
      .not.toBe(stableAttachmentId({ ...base, data: 'data:text/plain;base64,REVG' }))
  })
})
