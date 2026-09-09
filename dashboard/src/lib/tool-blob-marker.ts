/**
 * Blob marker parser for tool outputs externalized via Tool_blob_store.
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

const MARKER_PREFIX = '[masc:blob '

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
  if (!text.startsWith(MARKER_PREFIX)) return null
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
  return text.startsWith(MARKER_PREFIX) && text.endsWith(']')
}

/**
 * Reverse of OCaml's `%S` quoting. `%S` escapes every byte outside printable
 * ASCII as a three-digit decimal `\DDD`, so a UTF-8 preview (Korean text,
 * the em-dash in `failure_class=<class> — <guidance>`) arrives one byte at a
 * time. Collect bytes and decode once; anything else `%S` emits is one of
 * `\\ \" \n \t \r \b`.
 */
function unescapeOcamlString(raw: string): string {
  const encoder = new TextEncoder()
  const bytes: number[] = []
  const pushText = (text: string): void => {
    for (const byte of encoder.encode(text)) bytes.push(byte)
  }
  let i = 0
  while (i < raw.length) {
    const slash = raw.indexOf('\\', i)
    if (slash === -1) {
      pushText(raw.slice(i))
      break
    }
    if (slash > i) pushText(raw.slice(i, slash))
    const next = raw[slash + 1]
    if (next === undefined) break // dangling backslash: nothing to decode
    const decimal = raw.slice(slash + 1, slash + 4)
    if (/^[0-9]{3}$/.test(decimal)) {
      bytes.push(Number(decimal) & 0xff)
      i = slash + 4
      continue
    }
    const hex = raw.slice(slash + 2, slash + 4)
    if (next === 'x' && /^[0-9a-fA-F]{2}$/.test(hex)) {
      bytes.push(parseInt(hex, 16))
      i = slash + 4
      continue
    }
    i = slash + 2
    switch (next) {
      case '\\': bytes.push(0x5c); break
      case '"': bytes.push(0x22); break
      case 'n': bytes.push(0x0a); break
      case 't': bytes.push(0x09); break
      case 'r': bytes.push(0x0d); break
      case 'b': bytes.push(0x08); break
      default: pushText(next) // unknown escape: keep the char
    }
  }
  return new TextDecoder().decode(Uint8Array.from(bytes))
}
