import { describe, it, expect } from 'vitest'
import {
  boardActorSigilLabel,
  boardPostHash,
  boardPostPermalink,
  boardPostTrackbackMarkdown,
  boardPostXShareUrl,
  dedupeLeadingHeading,
  stripInlineMarkdown,
} from './board-utils'

describe('stripInlineMarkdown', () => {
  it('strips bold markers', () => {
    expect(stripInlineMarkdown('**Hello World**')).toBe('Hello World')
  })

  it('strips underscore bold markers', () => {
    expect(stripInlineMarkdown('__Hello World__')).toBe('Hello World')
  })

  it('strips italic markers', () => {
    expect(stripInlineMarkdown('*italic text*')).toBe('italic text')
  })

  it('strips underscore italic markers', () => {
    expect(stripInlineMarkdown('_italic text_')).toBe('italic text')
  })

  it('strips inline code markers', () => {
    expect(stripInlineMarkdown('`code`')).toBe('code')
  })

  it('strips mixed formatting', () => {
    expect(stripInlineMarkdown('**Bold** and *italic* and `code`'))
      .toBe('Bold and italic and code')
  })

  it('preserves plain text', () => {
    expect(stripInlineMarkdown('plain text')).toBe('plain text')
  })

  it('handles empty string', () => {
    expect(stripInlineMarkdown('')).toBe('')
  })
})

describe('dedupeLeadingHeading', () => {
  it('removes leading heading identical to title', () => {
    const body = '# 주간 리포트\n이번 주 진행 내용입니다.'
    expect(dedupeLeadingHeading('주간 리포트', body))
      .toBe('이번 주 진행 내용입니다.')
  })

  it('keeps leading heading when it differs from title (intentional section)', () => {
    const body = '# 요약\n세부 내용입니다.'
    expect(dedupeLeadingHeading('주간 리포트', body))
      .toBe('# 요약\n세부 내용입니다.')
  })

  it('normalizes inline markdown in title before comparing', () => {
    const body = '# 제목\n본문'
    expect(dedupeLeadingHeading('**제목**', body)).toBe('본문')
  })

  it('handles h2..h6 the same as h1', () => {
    const body = '### 같은 제목\n본문'
    expect(dedupeLeadingHeading('같은 제목', body)).toBe('본문')
  })

  it('returns body unchanged when no heading present', () => {
    expect(dedupeLeadingHeading('제목', '본문만 있습니다.'))
      .toBe('본문만 있습니다.')
  })

  it('returns body unchanged when title is empty', () => {
    expect(dedupeLeadingHeading('', '# 제목\n본문')).toBe('# 제목\n본문')
  })

  it('strips leading heading marker from title when comparing', () => {
    // title 자체가 '# 제목' 형태여도 정규화하여 body 첫 헤더와 비교한다
    expect(dedupeLeadingHeading('# 제목', '# 제목\n본문')).toBe('본문')
  })
})

describe('board post sharing helpers', () => {
  it('builds the canonical board hash route for a post', () => {
    expect(boardPostHash('post 1')).toBe('#board?post=post%201')
  })

  it('builds an absolute permalink from the current dashboard URL', () => {
    expect(boardPostPermalink(
      'p-1',
      'http://localhost:5179/dashboard/#board',
    )).toBe('http://localhost:5179/dashboard/#board?post=p-1')
  })

  it('builds markdown trackback text with stripped title markdown', () => {
    expect(boardPostTrackbackMarkdown(
      { id: 'p-1', title: '**Idea** post' },
      'http://localhost:5179/dashboard/#board',
    )).toBe('[Idea post](http://localhost:5179/dashboard/#board?post=p-1)')
  })

  it('builds an X share intent URL with the board permalink', () => {
    const url = new URL(boardPostXShareUrl(
      { id: 'p-1', title: 'Share me' },
      'http://localhost:5179/dashboard/#board',
    ))

    expect(url.origin).toBe('https://twitter.com')
    expect(url.pathname).toBe('/intent/tweet')
    expect(url.searchParams.get('text')).toBe('Share me - MASC Board')
    expect(url.searchParams.get('url')).toBe('http://localhost:5179/dashboard/#board?post=p-1')
  })
})

describe('boardActorSigilLabel', () => {
  it('prefers the specific display name over a generic keeper key', () => {
    expect(boardActorSigilLabel('keeper', {
      kind: 'keeper',
      id: 'sangsu',
      key: 'keeper',
      display_name: 'sangsu',
      raw: 'keeper-sangsu-agent',
    })).toBe('sangsu')
  })
})
