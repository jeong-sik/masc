// Lightweight zero-dependency TOML 1.0 AST parser with exact source ranges/locations.
// Replaces `toml-eslint-parser` for structured runtime.toml editing while server-side
// `/api/v1/config/patch` & `/api/v1/config/raw/preview` remain authoritative.

export class ParseError extends Error {
  readonly lineNumber: number
  readonly column: number
  readonly index: number

  constructor(message: string, index: number, lineNumber: number, column: number) {
    super(message)
    this.name = 'ParseError'
    this.index = index
    this.lineNumber = lineNumber
    this.column = column
  }
}

export namespace AST {
  export interface Position {
    readonly line: number
    readonly column: number
  }
  export interface SourceLocation {
    readonly start: Position
    readonly end: Position
  }
  export interface TOMLBare {
    readonly type: 'TOMLBare'
    readonly name: string
    readonly range: [number, number]
    readonly loc: SourceLocation
  }
  export interface TOMLQuoted {
    readonly type: 'TOMLQuoted'
    readonly value: string
    readonly range: [number, number]
    readonly loc: SourceLocation
  }
  export interface TOMLKey {
    readonly type: 'TOMLKey'
    readonly keys: Array<TOMLBare | TOMLQuoted>
    readonly range: [number, number]
    readonly loc: SourceLocation
  }
  export type TOMLValue =
    | {
        readonly type: 'TOMLValue'
        readonly kind: 'string'
        readonly value: string
        readonly range: [number, number]
        readonly loc: SourceLocation
      }
    | {
        readonly type: 'TOMLValue'
        readonly kind: 'integer' | 'float'
        readonly value: number
        readonly range: [number, number]
        readonly loc: SourceLocation
      }
    | {
        readonly type: 'TOMLValue'
        readonly kind: 'boolean'
        readonly value: boolean
        readonly range: [number, number]
        readonly loc: SourceLocation
      }
  export interface TOMLArray {
    readonly type: 'TOMLArray'
    readonly elements: TOMLContentNode[]
    readonly range: [number, number]
    readonly loc: SourceLocation
  }
  export interface TOMLInlineTable {
    readonly type: 'TOMLInlineTable'
    readonly body: TOMLKeyValue[]
    readonly range: [number, number]
    readonly loc: SourceLocation
  }
  export type TOMLContentNode = TOMLValue | TOMLArray | TOMLInlineTable
  export interface TOMLKeyValue {
    readonly type: 'TOMLKeyValue'
    readonly key: TOMLKey
    readonly value: TOMLContentNode
    readonly range: [number, number]
    readonly loc: SourceLocation
  }
  export interface TOMLTable {
    readonly type: 'TOMLTable'
    readonly kind: 'standard' | 'array'
    readonly key: TOMLKey
    readonly body: TOMLKeyValue[]
    readonly range: [number, number]
    readonly loc: SourceLocation
  }
  export interface TOMLTopLevelTable {
    readonly type: 'TOMLTopLevelTable'
    readonly body: Array<TOMLTable | TOMLKeyValue>
    readonly range: [number, number]
    readonly loc: SourceLocation
  }
  export interface TOMLProgram {
    readonly type: 'TOMLProgram'
    readonly body: [TOMLTopLevelTable]
    readonly range: [number, number]
    readonly loc: SourceLocation
  }
}

class TomlParser {
  private pos = 0
  private readonly lineStarts: number[]

  constructor(private readonly src: string) {
    this.lineStarts = [0]
    for (let i = 0; i < src.length; i++) {
      if (src.charCodeAt(i) === 10) this.lineStarts.push(i + 1)
    }
  }

  private locAt(index: number): AST.Position {
    let lo = 0
    let hi = this.lineStarts.length - 1
    while (lo <= hi) {
      const mid = (lo + hi) >> 1
      if (this.lineStarts[mid]! <= index) lo = mid + 1
      else hi = mid - 1
    }
    const lineIdx = Math.max(0, hi)
    return { line: lineIdx + 1, column: index - this.lineStarts[lineIdx]! }
  }

  private locRange(start: number, end: number): AST.SourceLocation {
    return { start: this.locAt(start), end: this.locAt(end) }
  }

  private fail(message: string, at = this.pos): never {
    const p = this.locAt(at)
    throw new ParseError(message, at, p.line, p.column)
  }

  private peek(offset = 0): string {
    return this.src[this.pos + offset] ?? ''
  }

  private skipInlineWs(): void {
    while (this.pos < this.src.length) {
      const ch = this.src[this.pos]
      if (ch === ' ' || ch === '\t') this.pos++
      else break
    }
  }

  private skipWsAndComments(allowNewline: boolean): void {
    while (this.pos < this.src.length) {
      const ch = this.src[this.pos]
      if (ch === ' ' || ch === '\t') {
        this.pos++
      } else if (allowNewline && (ch === '\n' || ch === '\r')) {
        this.pos++
      } else if (ch === '#') {
        while (this.pos < this.src.length && this.src[this.pos] !== '\n') this.pos++
      } else {
        break
      }
    }
  }

  private expectLineEnd(): void {
    this.skipInlineWs()
    if (this.peek() === '#') {
      while (this.pos < this.src.length && this.src[this.pos] !== '\n') this.pos++
    }
    if (this.pos >= this.src.length) return
    if (this.peek() === '\r') {
      this.pos++
      if (this.peek() === '\n') this.pos++
      return
    }
    if (this.peek() === '\n') {
      this.pos++
      return
    }
    this.fail(`Unexpected token ${JSON.stringify(this.peek())}`)
  }

  parse(): AST.TOMLProgram {
    const body: Array<AST.TOMLTable | AST.TOMLKeyValue> = []
    let currentTable: AST.TOMLTable | null = null

    while (this.pos < this.src.length) {
      this.skipWsAndComments(true)
      if (this.pos >= this.src.length) break

      if (this.peek() === '[') {
        const table = this.parseTableHeader()
        body.push(table)
        currentTable = table
      } else {
        const kv = this.parseKeyValue()
        this.expectLineEnd()
        if (currentTable) {
          currentTable.body.push(kv)
        } else {
          body.push(kv)
        }
      }
    }

    const end = this.src.length
    const top: AST.TOMLTopLevelTable = {
      type: 'TOMLTopLevelTable',
      body,
      range: [0, end],
      loc: this.locRange(0, end),
    }
    this.validateTree(top)
    return {
      type: 'TOMLProgram',
      body: [top],
      range: [0, end],
      loc: this.locRange(0, end),
    }
  }

  private validateTree(top: AST.TOMLTopLevelTable): void {
    type Node =
      | { kind: 'value' }
      | { kind: 'inline'; children: Map<string, Node> }
      | { kind: 'table'; explicit: boolean; dotted: boolean; children: Map<string, Node> }
      | { kind: 'array'; items: Array<{ kind: 'table'; explicit: boolean; dotted: boolean; children: Map<string, Node> }> }

    const root: { kind: 'table'; explicit: boolean; dotted: boolean; children: Map<string, Node> } = {
      kind: 'table',
      explicit: true,
      dotted: false,
      children: new Map(),
    }

    const buildValueNode = (val: AST.TOMLContentNode): Node => {
      if (val.type === 'TOMLInlineTable') {
        const inlineNode: { kind: 'inline'; children: Map<string, Node> } = {
          kind: 'inline',
          children: new Map(),
        }
        for (const kv of val.body) {
          defineKeyValue(inlineNode, kv)
        }
        return inlineNode
      }
      return { kind: 'value' }
    }

    const defineKeyValue = (
      container: { kind: 'table' | 'inline'; children: Map<string, Node> },
      kv: AST.TOMLKeyValue,
    ): void => {
      const segs = keySegments(kv.key)
      let cur: { kind: 'table' | 'inline'; children: Map<string, Node> } = container
      for (let i = 0; i < segs.length - 1; i++) {
        const seg = segs[i]!
        const existing = cur.children.get(seg)
        if (!existing) {
          const created: Node = { kind: 'table', explicit: false, dotted: true, children: new Map() }
          cur.children.set(seg, created)
          cur = created
        } else if (existing.kind === 'table' && existing.dotted) {
          cur = existing
        } else {
          this.fail(`Cannot extend key "${seg}"`, kv.key.range[0])
        }
      }
      const leaf = segs[segs.length - 1]!
      if (cur.children.has(leaf)) {
        this.fail(`Duplicate key "${leaf}"`, kv.key.range[0])
      }
      cur.children.set(leaf, buildValueNode(kv.value))
    }

    const resolveHeader = (
      table: AST.TOMLTable,
    ): { kind: 'table'; explicit: boolean; dotted: boolean; children: Map<string, Node> } => {
      const segs = keySegments(table.key)
      let cur: { kind: 'table'; explicit: boolean; dotted: boolean; children: Map<string, Node> } = root
      for (let i = 0; i < segs.length - 1; i++) {
        const seg = segs[i]!
        const existing = cur.children.get(seg)
        if (!existing) {
          const created: Node = { kind: 'table', explicit: false, dotted: false, children: new Map() }
          cur.children.set(seg, created)
          cur = created
        } else if (existing.kind === 'table') {
          cur = existing
        } else if (existing.kind === 'array' && existing.items.length > 0) {
          cur = existing.items[existing.items.length - 1]!
        } else {
          this.fail(`Cannot define table under "${seg}"`, table.key.range[0])
        }
      }
      const leaf = segs[segs.length - 1]!
      const existing = cur.children.get(leaf)
      if (table.kind === 'array') {
        if (!existing) {
          const elem = { kind: 'table' as const, explicit: true, dotted: false, children: new Map<string, Node>() }
          cur.children.set(leaf, { kind: 'array', items: [elem] })
          return elem
        }
        if (existing.kind === 'array') {
          const elem = { kind: 'table' as const, explicit: true, dotted: false, children: new Map<string, Node>() }
          existing.items.push(elem)
          return elem
        }
        this.fail(`Cannot redefine "${leaf}" as array of tables`, table.key.range[0])
      } else {
        if (!existing) {
          const created = { kind: 'table' as const, explicit: true, dotted: false, children: new Map<string, Node>() }
          cur.children.set(leaf, created)
          return created
        }
        if (existing.kind === 'table' && !existing.explicit && !existing.dotted) {
          existing.explicit = true
          return existing
        }
        this.fail(`Duplicate or non-reopenable table "${leaf}"`, table.key.range[0])
      }
    }

    for (const entry of top.body) {
      if (entry.type === 'TOMLKeyValue') {
        defineKeyValue(root, entry)
      } else {
        const target = resolveHeader(entry)
        for (const kv of entry.body) {
          defineKeyValue(target, kv)
        }
      }
    }
  }

  private parseTableHeader(): AST.TOMLTable {
    const start = this.pos
    this.pos++ // '['
    let kind: 'standard' | 'array' = 'standard'
    if (this.peek() === '[') {
      kind = 'array'
      this.pos++
    }
    this.skipInlineWs()
    const key = this.parseKey()
    this.skipInlineWs()
    if (this.peek() !== ']') this.fail('Expected "]" to close table header')
    this.pos++
    if (kind === 'array') {
      if (this.peek() !== ']') this.fail('Expected "]]" to close array table header')
      this.pos++
    }
    const end = this.pos
    this.expectLineEnd()
    return {
      type: 'TOMLTable',
      kind,
      key,
      body: [],
      range: [start, end],
      loc: this.locRange(start, end),
    }
  }

  private parseKey(): AST.TOMLKey {
    const start = this.pos
    const keys: Array<AST.TOMLBare | AST.TOMLQuoted> = []
    keys.push(this.parseKeySegment())
    while (true) {
      this.skipInlineWs()
      if (this.peek() !== '.') break
      this.pos++
      this.skipInlineWs()
      keys.push(this.parseKeySegment())
    }
    const end = keys[keys.length - 1]!.range[1]
    return {
      type: 'TOMLKey',
      keys,
      range: [start, end],
      loc: this.locRange(start, end),
    }
  }

  private parseKeySegment(): AST.TOMLBare | AST.TOMLQuoted {
    const start = this.pos
    const ch = this.peek()
    if (ch === '"' || ch === "'") {
      const value = ch === '"' ? this.parseBasicString(false) : this.parseLiteralString(false)
      const end = this.pos
      return {
        type: 'TOMLQuoted',
        value,
        range: [start, end],
        loc: this.locRange(start, end),
      }
    }
    while (this.pos < this.src.length && /[A-Za-z0-9_-]/.test(this.src[this.pos]!)) {
      this.pos++
    }
    if (this.pos === start) {
      this.fail('Expected TOML key')
    }
    const name = this.src.slice(start, this.pos)
    return {
      type: 'TOMLBare',
      name,
      range: [start, this.pos],
      loc: this.locRange(start, this.pos),
    }
  }

  private parseKeyValue(): AST.TOMLKeyValue {
    const start = this.pos
    const key = this.parseKey()
    this.skipInlineWs()
    if (this.peek() !== '=') this.fail('Expected "=" after key')
    this.pos++
    this.skipInlineWs()
    const value = this.parseValue()
    const end = value.range[1]
    return {
      type: 'TOMLKeyValue',
      key,
      value,
      range: [start, end],
      loc: this.locRange(start, end),
    }
  }

  private parseValue(): AST.TOMLContentNode {
    const start = this.pos
    const ch = this.peek()
    if (ch === '"') {
      const multiline = this.src.startsWith('"""', this.pos)
      const value = this.parseBasicString(multiline)
      return { type: 'TOMLValue', kind: 'string', value, range: [start, this.pos], loc: this.locRange(start, this.pos) }
    }
    if (ch === "'") {
      const multiline = this.src.startsWith("'''", this.pos)
      const value = this.parseLiteralString(multiline)
      return { type: 'TOMLValue', kind: 'string', value, range: [start, this.pos], loc: this.locRange(start, this.pos) }
    }
    if (ch === '[') return this.parseArray()
    if (ch === '{') return this.parseInlineTable()
    if (this.src.startsWith('true', this.pos) && !/[A-Za-z0-9_-]/.test(this.peek(4))) {
      this.pos += 4
      return { type: 'TOMLValue', kind: 'boolean', value: true, range: [start, this.pos], loc: this.locRange(start, this.pos) }
    }
    if (this.src.startsWith('false', this.pos) && !/[A-Za-z0-9_-]/.test(this.peek(5))) {
      this.pos += 5
      return { type: 'TOMLValue', kind: 'boolean', value: false, range: [start, this.pos], loc: this.locRange(start, this.pos) }
    }
    return this.parseNumber()
  }

  private parseBasicString(multiline: boolean): string {
    const quote = multiline ? '"""' : '"'
    this.pos += quote.length
    if (multiline) {
      if (this.peek() === '\r' && this.peek(1) === '\n') this.pos += 2
      else if (this.peek() === '\n') this.pos += 1
    }
    let out = ''
    while (this.pos < this.src.length) {
      if (multiline && this.src.startsWith('"""', this.pos)) {
        // Handle up to 2 extra quotes before closing """
        let q = 0
        while (this.src[this.pos + q] === '"') q++
        if (q > 5) this.fail('Too many quotes in multiline string')
        out += '"'.repeat(q - 3)
        this.pos += q
        return out
      }
      const ch = this.src[this.pos]!
      if (!multiline && (ch === '\n' || ch === '\r')) this.fail('Unterminated string literal')
      if (!multiline && ch === '"') {
        this.pos++
        return out
      }
      if (ch === '\\') {
        this.pos++
        const esc = this.src[this.pos]
        if (multiline && (esc === ' ' || esc === '\t' || esc === '\r' || esc === '\n')) {
          while (this.pos < this.src.length && /[ \t\r\n]/.test(this.src[this.pos]!)) this.pos++
          continue
        }
        this.pos++
        switch (esc) {
          case 'b': out += '\b'; break
          case 't': out += '\t'; break
          case 'n': out += '\n'; break
          case 'f': out += '\f'; break
          case 'r': out += '\r'; break
          case '"': out += '"'; break
          case '\\': out += '\\'; break
          case 'u': {
            const hex = this.src.slice(this.pos, this.pos + 4)
            if (!/^[0-9a-fA-F]{4}$/.test(hex)) this.fail('Invalid \\u escape')
            out += String.fromCodePoint(parseInt(hex, 16))
            this.pos += 4
            break
          }
          case 'U': {
            const hex = this.src.slice(this.pos, this.pos + 8)
            if (!/^[0-9a-fA-F]{8}$/.test(hex)) this.fail('Invalid \\U escape')
            out += String.fromCodePoint(parseInt(hex, 16))
            this.pos += 8
            break
          }
          default:
            this.fail(`Invalid escape sequence \\${esc ?? ''}`)
        }
        continue
      }
      out += ch
      this.pos++
    }
    this.fail('Unterminated string literal')
  }

  private parseLiteralString(multiline: boolean): string {
    const quote = multiline ? "'''" : "'"
    this.pos += quote.length
    if (multiline) {
      if (this.peek() === '\r' && this.peek(1) === '\n') this.pos += 2
      else if (this.peek() === '\n') this.pos += 1
    }
    const start = this.pos
    while (this.pos < this.src.length) {
      if (multiline && this.src.startsWith("'''", this.pos)) {
        let q = 0
        while (this.src[this.pos + q] === "'") q++
        if (q > 5) this.fail('Too many quotes in multiline literal string')
        const out = this.src.slice(start, this.pos + (q - 3))
        this.pos += q
        return out
      }
      const ch = this.src[this.pos]!
      if (!multiline && (ch === '\n' || ch === '\r')) this.fail('Unterminated literal string')
      if (!multiline && ch === "'") {
        const out = this.src.slice(start, this.pos)
        this.pos++
        return out
      }
      this.pos++
    }
    this.fail('Unterminated literal string')
  }

  private parseArray(): AST.TOMLArray {
    const start = this.pos
    this.pos++ // '['
    const elements: AST.TOMLContentNode[] = []
    while (true) {
      this.skipWsAndComments(true)
      if (this.peek() === ']') {
        this.pos++
        return { type: 'TOMLArray', elements, range: [start, this.pos], loc: this.locRange(start, this.pos) }
      }
      if (this.pos >= this.src.length) this.fail('Unterminated array')
      elements.push(this.parseValue())
      this.skipWsAndComments(true)
      if (this.peek() === ',') {
        this.pos++
      } else if (this.peek() === ']') {
        this.pos++
        return { type: 'TOMLArray', elements, range: [start, this.pos], loc: this.locRange(start, this.pos) }
      } else {
        this.fail('Expected "," or "]" in array')
      }
    }
  }

  private parseInlineTable(): AST.TOMLInlineTable {
    const start = this.pos
    this.pos++ // '{'
    const body: AST.TOMLKeyValue[] = []
    this.skipInlineWs()
    if (this.peek() === '}') {
      this.pos++
      return { type: 'TOMLInlineTable', body, range: [start, this.pos], loc: this.locRange(start, this.pos) }
    }
    while (true) {
      this.skipInlineWs()
      if (this.peek() === '\n' || this.peek() === '\r' || this.pos >= this.src.length) {
        this.fail('Unterminated inline table')
      }
      body.push(this.parseKeyValue())
      this.skipInlineWs()
      if (this.peek() === ',') {
        this.pos++
        this.skipInlineWs()
        if (this.peek() === '}') this.fail('Trailing comma not allowed in TOML 1.0 inline table')
      } else if (this.peek() === '}') {
        this.pos++
        return { type: 'TOMLInlineTable', body, range: [start, this.pos], loc: this.locRange(start, this.pos) }
      } else {
        this.fail('Expected "," or "}" in inline table')
      }
    }
  }

  private parseNumber(): AST.TOMLValue {
    const start = this.pos
    while (this.pos < this.src.length && !/[ \t\r\n,\]}#]/.test(this.src[this.pos]!)) {
      this.pos++
    }
    const raw = this.src.slice(start, this.pos)
    if (!raw) this.fail('Expected TOML value', start)
    const clean = raw.replaceAll('_', '')
    if (/^[+-]?(?:0x[0-9a-fA-F]+|0o[0-7]+|0b[01]+)$/.test(clean)) {
      const sign = clean.startsWith('-') ? -1 : 1
      const body = clean.replace(/^[+-]/, '')
      const num = sign * Number(body)
      return { type: 'TOMLValue', kind: 'integer', value: num, range: [start, this.pos], loc: this.locRange(start, this.pos) }
    }
    if (/^[+-]?\d+$/.test(clean)) {
      return { type: 'TOMLValue', kind: 'integer', value: Number(clean), range: [start, this.pos], loc: this.locRange(start, this.pos) }
    }
    if (/^[+-]?(?:\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|inf|nan)$/.test(clean)) {
      const num = clean === 'inf' || clean === '+inf' ? Infinity : clean === '-inf' ? -Infinity : clean.endsWith('nan') ? NaN : Number(clean)
      return { type: 'TOMLValue', kind: 'float', value: num, range: [start, this.pos], loc: this.locRange(start, this.pos) }
    }
    this.fail(`Invalid TOML value ${JSON.stringify(raw)}`, start)
  }
}

export function parseTOML(source: string, _options?: { readonly tomlVersion?: string }): AST.TOMLProgram {
  return new TomlParser(source).parse()
}

function keySegments(key: AST.TOMLKey): string[] {
  return key.keys.map(part => (part.type === 'TOMLBare' ? part.name : part.value))
}

function setNested(target: Record<string, unknown>, path: readonly string[], value: unknown): void {
  let cursor = target
  for (let i = 0; i < path.length - 1; i++) {
    const part = path[i]!
    const next = Object.prototype.hasOwnProperty.call(cursor, part) ? cursor[part] : undefined
    if (typeof next === 'object' && next !== null && !Array.isArray(next)) {
      cursor = next as Record<string, unknown>
    } else {
      const created: Record<string, unknown> = Object.create(null)
      cursor[part] = created
      cursor = created
    }
  }
  cursor[path[path.length - 1]!] = value
}

export function getStaticTOMLValue(node: AST.TOMLKey): string[]
export function getStaticTOMLValue(node: AST.TOMLProgram | AST.TOMLTopLevelTable | AST.TOMLInlineTable): Record<string, unknown>
export function getStaticTOMLValue(node: AST.TOMLContentNode): unknown
export function getStaticTOMLValue(node: AST.TOMLProgram | AST.TOMLTopLevelTable | AST.TOMLKey | AST.TOMLContentNode): unknown {
  switch (node.type) {
    case 'TOMLKey':
      return keySegments(node)
    case 'TOMLValue':
      return node.value
    case 'TOMLArray':
      return node.elements.map(el => getStaticTOMLValue(el))
    case 'TOMLInlineTable': {
      const out: Record<string, unknown> = Object.create(null)
      for (const kv of node.body) {
        setNested(out, keySegments(kv.key), getStaticTOMLValue(kv.value))
      }
      return out
    }
    case 'TOMLProgram':
      return getStaticTOMLValue(node.body[0])
    case 'TOMLTopLevelTable': {
      const root: Record<string, unknown> = Object.create(null)
      for (const entry of node.body) {
        if (entry.type === 'TOMLKeyValue') {
          setNested(root, keySegments(entry.key), getStaticTOMLValue(entry.value))
        } else {
          const tablePath = keySegments(entry.key)
          if (entry.kind === 'array') {
            const parentPath = tablePath.slice(0, -1)
            const leaf = tablePath[tablePath.length - 1]!
            let parent = root
            for (const part of parentPath) {
              if (!Object.prototype.hasOwnProperty.call(parent, part) || typeof parent[part] !== 'object' || parent[part] === null) {
                parent[part] = Object.create(null)
              }
              parent = parent[part] as Record<string, unknown>
            }
            if (!Array.isArray(parent[leaf])) parent[leaf] = []
            const item: Record<string, unknown> = Object.create(null)
            for (const kv of entry.body) {
              setNested(item, keySegments(kv.key), getStaticTOMLValue(kv.value))
            }
            ;(parent[leaf] as unknown[]).push(item)
          } else {
            let tbl = root
            for (const part of tablePath) {
              if (!Object.prototype.hasOwnProperty.call(tbl, part) || typeof tbl[part] !== 'object' || tbl[part] === null) {
                tbl[part] = Object.create(null)
              }
              tbl = tbl[part] as Record<string, unknown>
            }
            for (const kv of entry.body) {
              setNested(tbl, keySegments(kv.key), getStaticTOMLValue(kv.value))
            }
          }
        }
      }
      return root
    }
  }
}
