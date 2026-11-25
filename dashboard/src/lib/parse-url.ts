export function parseUrl(input: string, base?: string): URL | null {
  try {
    return new URL(input, base)
  } catch {
    return null
  }
}
