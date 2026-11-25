const MEDIA_PREFIX = '/api/v1/media/'
const STORE_TOKEN = /^[0-9a-f]{64}$/
const RASTER_MIMES = new Set(['image/png', 'image/jpeg', 'image/jpg', 'image/gif', 'image/webp'])

export function isWorkspaceMediaPath(value: unknown): value is string {
  if (typeof value !== 'string' || !value.startsWith(MEDIA_PREFIX)) return false
  const token = value.slice(MEDIA_PREFIX.length)
  return token.length === 64 && STORE_TOKEN.test(token)
}

export function isWorkspaceRasterMime(value: unknown): value is string {
  return typeof value === 'string' && RASTER_MIMES.has(value.toLowerCase())
}
