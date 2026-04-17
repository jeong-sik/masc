const URL_PATTERN = /https?:\/\/[^\s<>"')\]]+[^\s<>"'.,;:!?)]/gi
const MARKDOWN_IMAGE_PATTERN = /!\[[^\]]*]\((https?:\/\/[^)\s]+)\)/gi
const STANDALONE_URL_PATTERN = /^<?(https?:\/\/\S+)>?$/

const IMAGE_EXTENSIONS = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.bmp', '.avif']

function isImageUrl(url: string): boolean {
  const normalized = url.toLowerCase()
  return IMAGE_EXTENSIONS.some(ext => normalized.endsWith(ext))
}

function cleanUrl(url: string): string {
  return url.replace(/[)>.,;:!?]+$/g, '')
}

export function convertStandaloneImageUrlsToMarkdown(text: string): string {
  return text
    .split('\n')
    .map(line => {
      const trimmed = line.trim()
      const match = trimmed.match(STANDALONE_URL_PATTERN)
      if (!match) return line
      const url = cleanUrl(match[1] ?? '')
      if (!url || !isImageUrl(url)) return line
      return line.replace(trimmed, `![](<${url}>)`)
    })
    .join('\n')
}

export function extractStandaloneImageUrls(text: string): string[] {
  return text
    .split('\n')
    .map(line => line.trim())
    .map(line => line.match(STANDALONE_URL_PATTERN)?.[1] ?? '')
    .map(cleanUrl)
    .filter(url => url !== '' && isImageUrl(url))
}

export function extractPreviewUrls(text: string, maxCount = 4): string[] {
  if (maxCount <= 0) return []
  const excluded = new Set<string>(extractStandaloneImageUrls(text))
  const withoutMarkdownImages = text.replace(MARKDOWN_IMAGE_PATTERN, '')
  const urls = withoutMarkdownImages.match(URL_PATTERN) ?? []
  const deduped: string[] = []

  for (const raw of urls) {
    const url = cleanUrl(raw)
    if (!url || excluded.has(url) || isImageUrl(url)) continue
    if (!deduped.includes(url)) deduped.push(url)
    if (deduped.length >= maxCount) break
  }

  return deduped
}

export function prepareRichContent(text: string, previewLimit = 4): {
  markdownText: string
  previewUrls: string[]
} {
  return {
    markdownText: convertStandaloneImageUrlsToMarkdown(text),
    previewUrls: extractPreviewUrls(text, previewLimit),
  }
}

export function hasRichMarkdownSignals(text: string): boolean {
  return /(^|\n)(`{3,}|~{3,}|#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s+|!\[[^\]]*]\(|https?:\/\/\S+)/m.test(text)
}
