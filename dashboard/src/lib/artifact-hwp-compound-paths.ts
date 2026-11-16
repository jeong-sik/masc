// UnicodeData 17.0.0, Simple_Uppercase_Mapping: Greek mappings whose full
// JavaScript uppercase expands. https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt
const simpleUppercase = new Map<number, number>([
  [0x1f80, 0x1f88], [0x1f81, 0x1f89], [0x1f82, 0x1f8a], [0x1f83, 0x1f8b],
  [0x1f84, 0x1f8c], [0x1f85, 0x1f8d], [0x1f86, 0x1f8e], [0x1f87, 0x1f8f],
  [0x1f90, 0x1f98], [0x1f91, 0x1f99], [0x1f92, 0x1f9a], [0x1f93, 0x1f9b],
  [0x1f94, 0x1f9c], [0x1f95, 0x1f9d], [0x1f96, 0x1f9e], [0x1f97, 0x1f9f],
  [0x1fa0, 0x1fa8], [0x1fa1, 0x1fa9], [0x1fa2, 0x1faa], [0x1fa3, 0x1fab],
  [0x1fa4, 0x1fac], [0x1fa5, 0x1fad], [0x1fa6, 0x1fae], [0x1fa7, 0x1faf],
  [0x1fb3, 0x1fbc], [0x1fc3, 0x1fcc], [0x1ff3, 0x1ffc],
])

/** MS-CFB §2.6.4: compare length, then single UTF-16 uppercase units; never expand. */
export function hwpCompoundNameKey(name: string): string {
  let units = ''
  for (let index = 0; index < name.length; index++) {
    const unit = name.charAt(index), simple = simpleUppercase.get(name.charCodeAt(index)), full = unit.toUpperCase()
    units += simple === undefined ? full.length === 1 ? full : unit : String.fromCharCode(simple)
  }
  return `${name.length}:${units}`
}

export interface HwpCompoundStreams extends ReadonlyMap<string, Uint8Array> {
  /** Case-insensitive CFB lookup; get() retains the original Map's exact-key behavior. */
  lookup(path: string): Uint8Array | undefined;
  pathsInStorage(storage: string): readonly string[];
  pathsWithName(name: string): readonly string[];
}
type Storage = { readonly kind: 'storage'; readonly children: Map<string, Node> }
type Node = Storage | { readonly kind: 'stream'; readonly path: string; readonly bytes: Uint8Array }

/** Index each path component once; iterators retain the original paths and byte arrays. */
export function indexHwpCompoundStreams(streams: ReadonlyMap<string, Uint8Array>): HwpCompoundStreams {
  const root: Storage = { kind: 'storage', children: new Map() }, byName = new Map<string, string[]>(), keys = new Map<string, string>()
  const keyFor = (name: string): string => {
    const known = keys.get(name)
    if (known !== undefined) return known
    const key = hwpCompoundNameKey(name); keys.set(name, key); return key
  }
  for (const [path, bytes] of streams) {
    const parts = path.split('/'); let directory = root
    for (let index = 0; index < parts.length; index++) {
      const key = keyFor(parts[index]!), existing = directory.children.get(key)
      if (index === parts.length - 1) {
        if (existing) throw new Error('CFB 경로가 겹칩니다.')
        directory.children.set(key, { kind: 'stream', path, bytes })
        const names = byName.get(key) ?? []; names.push(path); byName.set(key, names)
      } else if (existing) {
        if (existing.kind !== 'storage') throw new Error('CFB stream과 storage 경로가 겹칩니다.')
        directory = existing
      } else {
        const child: Storage = { kind: 'storage', children: new Map() }
        directory.children.set(key, child); directory = child
      }
    }
  }
  const find = (path: string): Node | undefined => {
    let node: Node = root
    if (path === '') return node
    for (const name of path.split('/')) {
      if (node.kind !== 'storage') return undefined
      const child = node.children.get(keyFor(name))
      if (!child) return undefined
      node = child
    }
    return node
  }
  const collection: HwpCompoundStreams = {
    size: streams.size,
    get: path => streams.get(path), has: path => streams.has(path),
    entries: () => streams.entries(), keys: () => streams.keys(), values: () => streams.values(),
    [Symbol.iterator]: () => streams[Symbol.iterator](),
    forEach(callback, thisArg?: unknown) { for (const [path, bytes] of streams) callback.call(thisArg, bytes, path, collection) },
    lookup(path) { const node = find(path); return node?.kind === 'stream' ? node.bytes : undefined },
    pathsInStorage(storage) {
      const node = find(storage)
      if (!node || node.kind !== 'storage') return []
      const pending: Node[] = [node], paths: string[] = []
      while (pending.length) {
        const next = pending.pop()!
        if (next.kind === 'stream') paths.push(next.path)
        else for (const child of next.children.values()) pending.push(child)
      }
      return paths
    },
    pathsWithName: name => byName.get(keyFor(name)) ?? [],
  }
  return collection
}
