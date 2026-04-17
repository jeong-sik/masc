/**
 * Sentinel marker parser for tool outputs externalized via Tool_blob_store.
 *
 * Produced by `lib/tool_bridge.ml::maybe_externalize` when a tool output
 * exceeds the threshold. The OCaml encoder uses:
 *
 *   Printf.sprintf "[masc:blob sha256=%s bytes=%d mime=%s preview=%S]"
 *
 * `%S` wraps the preview in OCaml string-literal quoting, which uses
 * `"..."` with backslash-escaped double quotes and special chars. We
 * decode by anchoring on the field separators rather than parsing the
 * full OCaml literal grammar — the preview never contains a literal `]`
 * because the OCaml side sanitizes control chars and we always close
 * with `]` as the last character.
 */

export const SENTINEL_PREFIX = '[masc:blob '

export interface ToolBlobMarker {
  sha256: string
  bytes: number
  mime: string
  preview: string
}

const MARKER_RE =
  /^\[masc:blob sha256=([0-9a-fA-F]{64}) bytes=(\d+) mime=(\S+) preview="((?:[^"\\]|\\.)*)"\]$/

/**
 * Strict check: the WHOLE string is a marker. Returns null when it isn't.
 * Used by render code that needs to switch UI between inline and lazy modes.
 */
export function parseToolBlobMarker(text: string): ToolBlobMarker | null {
  if (!text.startsWith(SENTINEL_PREFIX)) return null
  const m = text.match(MARKER_RE)
  if (!m) return null
  const [, sha, bytes, mime, preview] = m
  if (sha === undefined || bytes === undefined || mime === undefined || preview === undefined) {
    return null
  }
  return {
    sha256: sha.toLowerCase(),
    bytes: Number(bytes),
    mime,
    preview: unescapeOcamlString(preview),
  }
}

/** Cheap precheck — useful in hot loops before allocating regex captures. */
export function isToolBlobMarker(text: string): boolean {
  return text.startsWith(SENTINEL_PREFIX) && text.endsWith(']')
}

/**
 * Reverse of OCaml's `%S` quoting. Handles the small subset that the
 * OCaml side actually emits after `Inference_utils.sanitize_text_utf8`
 * (no control chars, but `\\`, `\"`, `\n`, `\t`, `\r` may appear).
 */
function unescapeOcamlString(raw: string): string {
  let out = ''
  for (let i = 0; i < raw.length; i++) {
    const c = raw[i]
    if (c !== '\\') {
      out += c
      continue
    }
    const next = raw[i + 1]
    i++
    switch (next) {
      case '\\': out += '\\'; break
      case '"': out += '"'; break
      case 'n': out += '\n'; break
      case 't': out += '\t'; break
      case 'r': out += '\r'; break
      default: out += next ?? '' // unknown escape: pass through next char
    }
  }
  return out
}
