import htm from 'htm'
import { h } from 'preact'
import type { ComponentType, ComponentChildren } from 'preact'

// Each instrumented HTM site owns its cache and source location. Creating
// native nodes here preserves Preact refs, keys, handlers and nested templates.
function bindSourceHtml(source: string) {
  return htm.bind((tag: string | ComponentType, props: Record<string, unknown> | null,
    ...children: ComponentChildren[]) => h(tag, typeof tag === 'string'
      ? { ...props, 'data-masc-source': source } : props, ...children))
}

// Source metadata includes file, expression position and source digest, so
// repeated calls share HTM's cache while changed HMR code gets a fresh site.
const sites = new Map<string, ReturnType<typeof bindSourceHtml>>()

export function sourceHtml(source: string) {
  const cached = sites.get(source)
  if (cached) return cached
  const tag = bindSourceHtml(source)
  sites.set(source, tag)
  return tag
}
