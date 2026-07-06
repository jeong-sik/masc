const URL_PATTERN = /https?:\/\/[^\s<>"')\]]+[^\s<>"'.,;:!?)]/gi
const MARKDOWN_IMAGE_PATTERN = /!\[[^\]]*]\((https?:\/\/[^)\s]+)\)/gi
const STANDALONE_URL_PATTERN = /^<?(https?:\/\/\S+)>?$/

const IMAGE_EXTENSIONS = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.bmp', '.avif']
const VIDEO_EXTENSIONS = ['.mp4', '.webm', '.ogv', '.mov', '.m4v']
const AUDIO_EXTENSIONS = ['.mp3', '.wav', '.m4a', '.aac', '.flac', '.oga', '.ogg']

export type RichMediaEmbed =
  | { kind: 'video'; url: string }
  | { kind: 'audio'; url: string }
  | { kind: 'iframe'; url: string; title: string }

function isImageUrl(url: string): boolean {
  const normalized = url.toLowerCase()
  return IMAGE_EXTENSIONS.some(ext => normalized.endsWith(ext))
}

function hasExtension(url: string, extensions: readonly string[]): boolean {
  let pathname = ''
  try {
    pathname = new URL(url).pathname
  } catch {
    pathname = url
  }
  const normalized = pathname.toLowerCase()
  return extensions.some(ext => normalized.endsWith(ext))
}

function isVideoUrl(url: string): boolean {
  return hasExtension(url, VIDEO_EXTENSIONS)
}

function isAudioUrl(url: string): boolean {
  return hasExtension(url, AUDIO_EXTENSIONS)
}

function cleanUrl(url: string): string {
  return url.replace(/[)>.,;:!?]+$/g, '')
}

function youtubeEmbedUrl(url: URL): string | null {
  const host = url.hostname.replace(/^www\./, '').toLowerCase()
  let id: string | null = null
  if (host === 'youtu.be') {
    id = url.pathname.split('/').filter(Boolean)[0] ?? null
  } else if (host === 'youtube.com' || host === 'youtube-nocookie.com') {
    if (url.pathname === '/watch') id = url.searchParams.get('v')
    else if (url.pathname.startsWith('/shorts/') || url.pathname.startsWith('/embed/')) {
      id = url.pathname.split('/').filter(Boolean)[1] ?? null
    }
  }
  if (!id || !/^[a-zA-Z0-9_-]{6,}$/.test(id)) return null
  return `https://www.youtube-nocookie.com/embed/${id}`
}

function vimeoEmbedUrl(url: URL): string | null {
  const host = url.hostname.replace(/^www\./, '').toLowerCase()
  if (host !== 'vimeo.com' && host !== 'player.vimeo.com') return null
  const id = url.pathname.split('/').filter(Boolean).find(part => /^\d+$/.test(part))
  return id ? `https://player.vimeo.com/video/${id}` : null
}

export function mediaEmbedForUrl(rawUrl: string): RichMediaEmbed | null {
  const url = cleanUrl(rawUrl)
  if (!url) return null
  if (isVideoUrl(url)) return { kind: 'video', url }
  if (isAudioUrl(url)) return { kind: 'audio', url }
  try {
    const parsed = new URL(url)
    const embedUrl = youtubeEmbedUrl(parsed) ?? vimeoEmbedUrl(parsed)
    return embedUrl ? { kind: 'iframe', url: embedUrl, title: parsed.hostname } : null
  } catch {
    return null
  }
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
  const mediaUrls = new Set(extractMediaEmbeds(text).map(embed => embed.url))
  const withoutMarkdownImages = text.replace(MARKDOWN_IMAGE_PATTERN, '')
  const urls = withoutMarkdownImages.match(URL_PATTERN) ?? []
  const deduped: string[] = []

  for (const raw of urls) {
    const url = cleanUrl(raw)
    const embed = mediaEmbedForUrl(url)
    if (!url || excluded.has(url) || isImageUrl(url)) continue
    if (embed && mediaUrls.has(embed.url)) continue
    if (!deduped.includes(url)) deduped.push(url)
    if (deduped.length >= maxCount) break
  }

  return deduped
}

export function extractMediaEmbeds(text: string, maxCount = 4): RichMediaEmbed[] {
  if (maxCount <= 0) return []
  const embeds: RichMediaEmbed[] = []
  for (const line of text.split('\n')) {
    const trimmed = line.trim()
    const match = trimmed.match(STANDALONE_URL_PATTERN)
    if (!match) continue
    const embed = mediaEmbedForUrl(match[1] ?? '')
    if (!embed) continue
    if (!embeds.some(existing => existing.kind === embed.kind && existing.url === embed.url)) {
      embeds.push(embed)
    }
    if (embeds.length >= maxCount) break
  }
  return embeds
}

function removeStandaloneMediaEmbedLines(text: string): string {
  return text
    .split('\n')
    .filter(line => {
      const match = line.trim().match(STANDALONE_URL_PATTERN)
      return !match || mediaEmbedForUrl(match[1] ?? '') === null
    })
    .join('\n')
}

export function prepareRichContent(text: string, previewLimit = 4): {
  markdownText: string
  previewUrls: string[]
  mediaEmbeds: RichMediaEmbed[]
} {
  const markdownSource = removeStandaloneMediaEmbedLines(text)
  return {
    markdownText: convertStandaloneImageUrlsToMarkdown(markdownSource),
    previewUrls: extractPreviewUrls(text, previewLimit),
    mediaEmbeds: extractMediaEmbeds(text, previewLimit),
  }
}

export function hasRichMarkdownSignals(text: string): boolean {
  return /(^|\n)(`{3,}|~{3,}|#{1,6}\s+|[-*+]\s+|\d+\.\s+|>\s+|!\[[^\]]*]\(|https?:\/\/\S+)/m.test(text)
}
