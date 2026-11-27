/**
 * Parse JSON without silently replacing an earlier duplicate object member.
 *
 * Strategy:
 * 1. Let V8's native C++ `JSON.parse` validate RFC 8259 syntax and construct `value`.
 * 2. If the raw text contains no `{`, return `value` immediately.
 * 3. Walk `raw` and `value` in lockstep with a flat iterative loop (zero nested
 *    closures, zero recursion, zero `Set` allocations, zero `raw.slice` for
 *    primitive properties). Because `JSON.parse` collapses duplicate members onto
 *    the same own property, every object `{ ... }` is duplicate-free iff its raw
 *    member count equals `Object.keys(obj).length` and every nested container
 *    matches the expected shape.
 */

function readChild(parent: Record<string, unknown>, key: string): unknown {
  return key === '__proto__'
    ? Object.getOwnPropertyDescriptor(parent, '__proto__')?.value
    : parent[key]
}

function verifyUniqueNoEscapes(raw: string, root: unknown): void {
  const len = raw.length
  let offset = 0

  const stackKind: number[] = []
  const stackObj: unknown[] = []
  const stackCount: number[] = []
  let depth = -1
  let curTarget: unknown = root
  // 0 = parse value for curTarget, 1 = parse next object key for stackObj[depth]
  let state = 0

  for (;;) {
    let c = raw.charCodeAt(offset)
    if (c <= 32) {
      while (c <= 32) c = raw.charCodeAt(++offset)
    }

    if (state === 1) {
      const keyStart = offset + 1
      const keyEnd = raw.indexOf('"', keyStart)
      if (keyEnd === -1) throw new Error('unterminated JSON string')
      offset = keyEnd + 1

      stackCount[depth] = stackCount[depth]! + 1

      c = raw.charCodeAt(offset)
      if (c <= 32) {
        while (c <= 32) c = raw.charCodeAt(++offset)
      }
      offset++ // ':'
      c = raw.charCodeAt(offset)
      if (c <= 32) {
        while (c <= 32) c = raw.charCodeAt(++offset)
      }

      if (c === 123 || c === 91) {
        const key = raw.slice(keyStart, keyEnd)
        curTarget = readChild(stackObj[depth] as Record<string, unknown>, key)
        state = 0
        continue
      }

      // Fast-skip primitive property value without slicing the key or leaving state 1.
      if (c === 34) {
        const q = raw.indexOf('"', offset + 1)
        if (q === -1) throw new Error('unterminated JSON string')
        offset = q + 1
      } else {
        while (offset < len) {
          const ch = raw.charCodeAt(offset)
          if (ch === 44 || ch === 125 || ch <= 32) break
          offset++
        }
      }

      c = raw.charCodeAt(offset)
      if (c <= 32) {
        while (c <= 32) c = raw.charCodeAt(++offset)
      }
      if (c === 44) {
        offset++
        continue
      }
      // '}'
      offset++
      if (Object.keys(stackObj[depth] as Record<string, unknown>).length !== stackCount[depth]!) {
        throw new Error('duplicate JSON member')
      }
      depth--
    } else if (c === 123) {
      if (typeof curTarget !== 'object' || curTarget === null || Array.isArray(curTarget)) {
        throw new Error('duplicate JSON member')
      }
      offset++
      c = raw.charCodeAt(offset)
      if (c <= 32) {
        while (c <= 32) c = raw.charCodeAt(++offset)
      }
      if (c === 125) {
        if (Object.keys(curTarget as Record<string, unknown>).length !== 0) {
          throw new Error('duplicate JSON member')
        }
        offset++
      } else {
        depth++
        stackKind[depth] = 0
        stackObj[depth] = curTarget
        stackCount[depth] = 0
        state = 1
        continue
      }
    } else if (c === 91) {
      if (!Array.isArray(curTarget)) {
        throw new Error('duplicate JSON member')
      }
      offset++
      c = raw.charCodeAt(offset)
      if (c <= 32) {
        while (c <= 32) c = raw.charCodeAt(++offset)
      }
      if (c === 93) {
        offset++
      } else {
        if (curTarget.length === 0) throw new Error('duplicate JSON member')
        depth++
        stackKind[depth] = 1
        stackObj[depth] = curTarget
        stackCount[depth] = 0
        curTarget = curTarget[0]
        continue
      }
    } else if (c === 34) {
      const q = raw.indexOf('"', offset + 1)
      if (q === -1) throw new Error('unterminated JSON string')
      offset = q + 1
    } else {
      while (offset < len) {
        const ch = raw.charCodeAt(offset)
        if (ch === 44 || ch === 93 || ch === 125 || ch <= 32) break
        offset++
      }
    }

    let resume = false
    while (depth >= 0) {
      c = raw.charCodeAt(offset)
      if (c <= 32) {
        while (c <= 32) c = raw.charCodeAt(++offset)
      }
      if (stackKind[depth] === 0) {
        if (c === 44) {
          offset++
          state = 1
          resume = true
          break
        }
        offset++
        if (Object.keys(stackObj[depth] as Record<string, unknown>).length !== stackCount[depth]!) {
          throw new Error('duplicate JSON member')
        }
        depth--
      } else {
        if (c === 44) {
          offset++
          const nextIdx = stackCount[depth]! + 1
          stackCount[depth] = nextIdx
          const arr = stackObj[depth] as unknown[]
          if (nextIdx >= arr.length) throw new Error('duplicate JSON member')
          curTarget = arr[nextIdx]
          state = 0
          resume = true
          break
        }
        offset++
        depth--
      }
    }
    if (!resume) return
  }
}

function verifyUniqueWithEscapes(raw: string, root: unknown, firstBackslash: number): void {
  const len = raw.length
  let offset = 0
  let nextBs = firstBackslash

  const stackKind: number[] = []
  const stackObj: unknown[] = []
  const stackCount: number[] = []
  let depth = -1
  let curTarget: unknown = root
  let state = 0

  for (;;) {
    let c = raw.charCodeAt(offset)
    if (c <= 32) {
      while (c <= 32) c = raw.charCodeAt(++offset)
    }

    if (state === 1) {
      const keyStart = offset
      offset++
      let keyHasEscape = false
      let keyEnd: number
      for (;;) {
        const q = raw.indexOf('"', offset)
        if (q === -1) throw new Error('unterminated JSON string')
        if (nextBs === -1 || nextBs > q) {
          keyEnd = q
          offset = q + 1
          break
        }
        keyHasEscape = true
        let bs = q - 1
        while (bs >= offset && raw.charCodeAt(bs) === 92) bs--
        offset = q + 1
        if (nextBs < offset) nextBs = raw.indexOf('\\', offset)
        if (((q - 1 - bs) & 1) === 0) {
          keyEnd = q
          break
        }
      }

      stackCount[depth] = stackCount[depth]! + 1

      c = raw.charCodeAt(offset)
      if (c <= 32) {
        while (c <= 32) c = raw.charCodeAt(++offset)
      }
      offset++ // ':'
      c = raw.charCodeAt(offset)
      if (c <= 32) {
        while (c <= 32) c = raw.charCodeAt(++offset)
      }

      if (c === 123 || c === 91) {
        const key = keyHasEscape
          ? (JSON.parse(raw.slice(keyStart, keyEnd + 1)) as string)
          : raw.slice(keyStart + 1, keyEnd)
        curTarget = readChild(stackObj[depth] as Record<string, unknown>, key)
        state = 0
        continue
      }

      if (c === 34) {
        offset++
        for (;;) {
          const q = raw.indexOf('"', offset)
          if (q === -1) throw new Error('unterminated JSON string')
          if (nextBs === -1 || nextBs > q) {
            offset = q + 1
            break
          }
          let bs = q - 1
          while (bs >= offset && raw.charCodeAt(bs) === 92) bs--
          offset = q + 1
          if (nextBs < offset) nextBs = raw.indexOf('\\', offset)
          if (((q - 1 - bs) & 1) === 0) break
        }
      } else {
        while (offset < len) {
          const ch = raw.charCodeAt(offset)
          if (ch === 44 || ch === 125 || ch <= 32) break
          offset++
        }
      }

      c = raw.charCodeAt(offset)
      if (c <= 32) {
        while (c <= 32) c = raw.charCodeAt(++offset)
      }
      if (c === 44) {
        offset++
        continue
      }
      offset++
      if (Object.keys(stackObj[depth] as Record<string, unknown>).length !== stackCount[depth]!) {
        throw new Error('duplicate JSON member')
      }
      depth--
    } else if (c === 123) {
      if (typeof curTarget !== 'object' || curTarget === null || Array.isArray(curTarget)) {
        throw new Error('duplicate JSON member')
      }
      offset++
      c = raw.charCodeAt(offset)
      if (c <= 32) {
        while (c <= 32) c = raw.charCodeAt(++offset)
      }
      if (c === 125) {
        if (Object.keys(curTarget as Record<string, unknown>).length !== 0) {
          throw new Error('duplicate JSON member')
        }
        offset++
      } else {
        depth++
        stackKind[depth] = 0
        stackObj[depth] = curTarget
        stackCount[depth] = 0
        state = 1
        continue
      }
    } else if (c === 91) {
      if (!Array.isArray(curTarget)) {
        throw new Error('duplicate JSON member')
      }
      offset++
      c = raw.charCodeAt(offset)
      if (c <= 32) {
        while (c <= 32) c = raw.charCodeAt(++offset)
      }
      if (c === 93) {
        offset++
      } else {
        if (curTarget.length === 0) throw new Error('duplicate JSON member')
        depth++
        stackKind[depth] = 1
        stackObj[depth] = curTarget
        stackCount[depth] = 0
        curTarget = curTarget[0]
        continue
      }
    } else if (c === 34) {
      offset++
      for (;;) {
        const q = raw.indexOf('"', offset)
        if (q === -1) throw new Error('unterminated JSON string')
        if (nextBs === -1 || nextBs > q) {
          offset = q + 1
          break
        }
        let bs = q - 1
        while (bs >= offset && raw.charCodeAt(bs) === 92) bs--
        offset = q + 1
        if (nextBs < offset) nextBs = raw.indexOf('\\', offset)
        if (((q - 1 - bs) & 1) === 0) break
      }
    } else {
      while (offset < len) {
        const ch = raw.charCodeAt(offset)
        if (ch === 44 || ch === 93 || ch === 125 || ch <= 32) break
        offset++
      }
    }

    let resume = false
    while (depth >= 0) {
      c = raw.charCodeAt(offset)
      if (c <= 32) {
        while (c <= 32) c = raw.charCodeAt(++offset)
      }
      if (stackKind[depth] === 0) {
        if (c === 44) {
          offset++
          state = 1
          resume = true
          break
        }
        offset++
        if (Object.keys(stackObj[depth] as Record<string, unknown>).length !== stackCount[depth]!) {
          throw new Error('duplicate JSON member')
        }
        depth--
      } else {
        if (c === 44) {
          offset++
          const nextIdx = stackCount[depth]! + 1
          stackCount[depth] = nextIdx
          const arr = stackObj[depth] as unknown[]
          if (nextIdx >= arr.length) throw new Error('duplicate JSON member')
          curTarget = arr[nextIdx]
          state = 0
          resume = true
          break
        }
        offset++
        depth--
      }
    }
    if (!resume) return
  }
}

export function parseUniqueJson(raw: string): unknown {
  const value: unknown = JSON.parse(raw)
  if (raw.indexOf('{') === -1) return value
  const firstBackslash = raw.indexOf('\\')
  if (firstBackslash === -1) {
    verifyUniqueNoEscapes(raw, value)
  } else {
    verifyUniqueWithEscapes(raw, value, firstBackslash)
  }
  return value
}
