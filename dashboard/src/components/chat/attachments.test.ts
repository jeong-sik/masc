import { describe, expect, it } from 'vitest'
import {
  ATTACHMENT_INPUT_ACCEPT,
  MAX_FILE_SIZE,
  MAX_IMAGE_SIZE,
  attachmentFromImageReference,
  resolveAttachmentMimeType,
  stableAttachmentId,
  validateFile,
  wholeImageUrl,
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

  it('accepts html files', () => {
    expect(validateFile(fileOfSize('report.html', 'text/html', 10))).toBeNull()
  })

  // Browsers commonly report an EMPTY File.type for .md/.html (platform MIME
  // table gaps) — exact-matching the declared type rejected markdown outright
  // (campaign #38). The extension fallback must recover the real type.
  it('accepts blank-MIME markdown and html via the extension fallback', () => {
    expect(validateFile(fileOfSize('notes.md', '', 10))).toBeNull()
    expect(validateFile(fileOfSize('notes.markdown', '', 10))).toBeNull()
    expect(validateFile(fileOfSize('page.html', '', 10))).toBeNull()
    expect(validateFile(fileOfSize('page.htm', '', 10))).toBeNull()
  })

  it('still rejects blank-MIME files with unmapped extensions', () => {
    expect(validateFile(fileOfSize('binary.exe', '', 10))).toContain('지원하지 않는 파일 형식')
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

describe('resolveAttachmentMimeType', () => {
  it('keeps a declared allow-listed type without consulting the extension', () => {
    expect(resolveAttachmentMimeType(fileOfSize('odd-name.bin', 'text/markdown', 10)))
      .toBe('text/markdown')
  })

  it('maps blank-MIME files by extension, case-insensitively', () => {
    expect(resolveAttachmentMimeType(fileOfSize('README.MD', '', 10))).toBe('text/markdown')
    expect(resolveAttachmentMimeType(fileOfSize('index.HTML', '', 10))).toBe('text/html')
  })

  it('keeps the declared type when the extension is unmapped', () => {
    expect(resolveAttachmentMimeType(fileOfSize('archive.zip', 'application/zip', 10)))
      .toBe('application/zip')
  })

  it('never overrides an explicit unsupported MIME type from the extension', () => {
    expect(resolveAttachmentMimeType(fileOfSize('renamed.md', 'application/x-msdownload', 10)))
      .toBe('application/x-msdownload')
    expect(validateFile(fileOfSize('renamed.md', 'application/x-msdownload', 10)))
      .toContain('지원하지 않는 파일 형식')
  })

  it('derives the file-picker accept contract from the MIME catalog', () => {
    expect(ATTACHMENT_INPUT_ACCEPT.split(',')).toEqual(expect.arrayContaining([
      'text/markdown',
      'text/html',
      '.md',
      '.html',
    ]))
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

describe('image reference attachments', () => {
  it('wholeImageUrl accepts a bare http(s) URL and rejects anything else', () => {
    expect(wholeImageUrl('https://example.test/a.png')).toBe('https://example.test/a.png')
    expect(wholeImageUrl('  http://example.test/a.jpg ')).toBe('http://example.test/a.jpg')
    expect(wholeImageUrl('HTTPS://EXAMPLE.TEST/A.PNG')).toBe('HTTPS://EXAMPLE.TEST/A.PNG')
    // Embedded in prose, or not a URL at all — stays text.
    expect(wholeImageUrl('see https://example.test/a.png please')).toBeNull()
    expect(wholeImageUrl('https://example.test/a.png https://other.test/b.png')).toBeNull()
    expect(wholeImageUrl('ftp://example.test/a.png')).toBeNull()
    expect(wholeImageUrl('file-abc123')).toBeNull()
    expect(wholeImageUrl('')).toBeNull()
  })

  it('builds a url reference attachment with a stable id', () => {
    const result = attachmentFromImageReference('https://example.test/a.png')
    if (!('attachment' in result)) throw new Error('expected an attachment')
    expect(result.attachment.kind).toBe('url')
    if (result.attachment.kind !== 'url') throw new Error('unreachable')
    expect(result.attachment.url).toBe('https://example.test/a.png')
    expect(result.attachment.name).toBe('https://example.test/a.png')
    expect(result.attachment.id).toMatch(/^ref-url-/)
    // Same reference value -> same id, so re-adding dedupes.
    const again = attachmentFromImageReference('https://example.test/a.png')
    if (!('attachment' in again)) throw new Error('expected an attachment')
    expect(again.attachment.id).toBe(result.attachment.id)
  })

  it('builds a file_id reference for a non-URL value', () => {
    const result = attachmentFromImageReference(' file-abc123 ')
    if (!('attachment' in result)) throw new Error('expected an attachment')
    expect(result.attachment.kind).toBe('file_id')
    if (result.attachment.kind !== 'file_id') throw new Error('unreachable')
    expect(result.attachment.fileId).toBe('file-abc123')
    expect(result.attachment.id).toMatch(/^ref-file-/)
  })

  it('rejects an empty reference', () => {
    expect(attachmentFromImageReference('   ')).toEqual({ error: '이미지 참조가 비어 있습니다.' })
  })
})
