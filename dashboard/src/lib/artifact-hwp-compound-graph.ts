//HIGH-RISK-UNREVIEWED: MS-CFB §§2.2–2.7 allocation graphs are the authority for stream reads.
const signature = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1] as const
const free = 0xffffffff, end = 0xfffffffe, fatSector = 0xfffffffd, difatSector = 0xfffffffc
const headerBytes = 512, directoryBytes = 128, miniBytes = 64, miniCutoff = 4096, headerDifatEntries = 109
type NameBytes = { readonly offset: number; readonly bytes: number }
type Directory = { readonly type: 0 | 1 | 2 | 5; readonly left: number; readonly right: number; readonly child: number; readonly start: number; readonly size: number; readonly name: NameBytes }
type DirectoryLocation = { readonly id: number; readonly parent: number; readonly depth: number }
export type CompoundEntry = DirectoryLocation & { readonly name: NameBytes } & (
  { readonly kind: 'storage' } | { readonly kind: 'stream'; readonly size: number; readonly allocation: 'fat' | 'mini';
    /** Full allocation chain, including any unused tail; every reference has one owner. */
    readonly sectors: readonly number[] }
)
export type CompoundLayout = {
  readonly sectorBytes: number;
  readonly miniSectorBytes: number;
  readonly miniStreamSectors: readonly number[];
  readonly rootName: NameBytes;
  /** Depth-first directory order, with each parent before its children. */
  readonly entries: readonly CompoundEntry[];
}

function damaged(detail: string): never { throw new Error(`CFB 연결 구조가 손상됐습니다: ${detail}`) }

function checkCycles(table: Uint32Array, count: number, label: string): void {
  const state = new Uint8Array(count)
  for (let first = 0; first < count; first++) {
    let at = first
    while (at < count && state[at] === 0) { state[at] = 1; at = table[at]! }
    if (at < count && state[at] === 1) damaged(`${label} 순환`)
    at = first
    while (at < count && state[at] === 1) { state[at] = 2; at = table[at]! }
  }
}

function chain(start: number, table: Uint32Array, owned: Uint8Array, label: string): number[] {
  const sectors: number[] = []
  for (let at = start; at !== end; at = table[at]!) {
    if (at >= owned.length || owned[at] !== 0) damaged(`${label} 범위·순환·중복 소속`)
    owned[at] = 1; sectors.push(at)
  }
  return sectors
}

/** Validate allocation and directory graphs, without reconstructing logical stream bytes. */
export function validateHwpCompoundGraph(data: Uint8Array): CompoundLayout {
  if (data.byteLength < headerBytes || !signature.every((byte, index) => data[index] === byte)) damaged('header 서명')
  const view = new DataView(data.buffer, data.byteOffset, data.byteLength)
  const u16 = (offset: number) => view.getUint16(offset, true), u32 = (offset: number) => view.getUint32(offset, true)
  const major = u16(26), shift = u16(30)
  if ((major !== 3 && major !== 4) || shift !== (major === 3 ? 9 : 12) || u16(28) !== 0xfffe
    || u16(32) !== 6 || data.subarray(8, 24).some(byte => byte !== 0) || data.subarray(34, 40).some(byte => byte !== 0)
    || u32(56) !== miniCutoff || (major === 3 && u32(40) !== 0)) damaged('header 필드')
  const sectorBytes = 2 ** shift, words = sectorBytes / 4, count = data.byteLength / sectorBytes - 1
  if (!Number.isInteger(count) || count < 1 || data.subarray(headerBytes, sectorBytes).some(byte => byte !== 0)) damaged('물리 sector 크기')
  const offset = (sector: number): number => { if (sector >= count) damaged('sector 범위'); return (sector + 1) * sectorBytes }
  const fatCount = u32(44), difatCount = u32(72), miniFatCount = u32(64)
  if (!fatCount || fatCount > count || difatCount > count || miniFatCount > count || fatCount * words < count) damaged('allocation table 개수')
  const fats: number[] = [], difats: number[] = [], fatIds = new Set<number>(), difatIds = new Set<number>()
  let unused = false
  const addFat = (id: number): void => {
    if (id === free) { unused = true; return }
    if (unused || id >= count || fatIds.has(id) || fats.length >= fatCount) damaged('DIFAT의 FAT 소속')
    fatIds.add(id); fats.push(id)
  }
  for (let index = 0; index < headerDifatEntries; index++) addFat(u32(76 + index * 4))
  let nextDifat = u32(68)
  for (let index = 0; index < difatCount; index++) {
    if (nextDifat >= count || difatIds.has(nextDifat)) damaged('DIFAT 범위·순환')
    const sector = offset(nextDifat)
    difatIds.add(nextDifat); difats.push(nextDifat)
    for (let word = 0; word < words - 1; word++) addFat(u32(sector + word * 4))
    nextDifat = u32(sector + sectorBytes - 4)
  }
  if (nextDifat !== end || fats.length !== fatCount) damaged('DIFAT 길이')
  const fat = new Uint32Array(count), owned = new Uint8Array(count)
  for (const id of [...fats, ...difats]) { if (owned[id]) damaged('FAT/DIFAT 중복 소속'); owned[id] = 1 }
  for (let index = 0; index < fats.length; index++) for (let word = 0; word < words; word++) {
    const id = index * words + word, value = u32(offset(fats[index]!) + word * 4)
    if (id >= count) { if (value !== free) damaged('FAT 파일 밖 allocation'); continue }
    if (value === fatSector ? !fatIds.has(id) : value === difatSector ? !difatIds.has(id)
      : value !== free && value !== end && value >= count) damaged('FAT sector 참조')
    fat[id] = value
  }
  for (const id of fats) if (fat[id] !== fatSector) damaged('FAT sector 표식')
  for (const id of difats) if (fat[id] !== difatSector) damaged('DIFAT sector 표식')
  checkCycles(fat, count, 'FAT')
  const directorySectors = chain(u32(48), fat, owned, 'directory FAT')
  if (!directorySectors.length || (major === 4 && directorySectors.length !== u32(40))) damaged('directory sector 개수')
  const entries: Directory[] = []
  for (const id of directorySectors) for (let within = 0; within < sectorBytes; within += directoryBytes) {
    const at = offset(id) + within, type = data[at + 66]!
    if (type !== 0 && type !== 1 && type !== 2 && type !== 5) damaged('directory object 종류')
    const left = u32(at + 68), right = u32(at + 72), child = u32(at + 76), start = u32(at + 116)
    // MS-CFB §2.6.3 requires readers to ignore old, uninitialized v3 high DWORDs.
    const size = major === 3 ? u32(at + 120) : Number(view.getBigUint64(at + 120, true))
    const nameLength = u16(at + 64)
    if (type === 0 ? left !== free || right !== free || child !== free || nameLength !== 0 || start !== 0 || size !== 0
      : nameLength < 2 || nameLength > 64 || nameLength % 2 !== 0 || u16(at + nameLength - 2) !== 0) damaged('directory entry 필드')
    if (type === 1 && (start !== 0 || size !== 0)) damaged('storage stream 필드')
    if ((type === 2 || type === 5) && size > data.byteLength) damaged('stream 크기가 물리 파일을 넘습니다')
    if (type === 2 && child !== free) damaged('stream의 child 참조')
    entries.push({ type, left, right, child, start, size, name: { offset: at, bytes: nameLength - 2 } })
  }
  const root = entries[0]!
  if (root.type !== 5 || root.left !== free || root.right !== free) damaged('directory root')
  const seen = new Uint8Array(entries.length), order: DirectoryLocation[] = [], pending: DirectoryLocation[] = [{ id: root.child, parent: 0, depth: 1 }]; seen[0] = 1
  while (pending.length) {
    const location = pending.pop()!, { id, parent, depth } = location
    if (id === free) continue
    const entry = entries[id]
    if (id === 0 || !entry || seen[id] || (entry.type !== 1 && entry.type !== 2)) damaged('directory 범위·순환·중복 소속')
    seen[id] = 1; order.push(location)
    pending.push({ id: entry.left, parent, depth }, { id: entry.right, parent, depth }, { id: entry.child, parent: id, depth: depth + 1 })
  }
  if (entries.some((entry, id) => entry.type !== 0 && !seen[id])) damaged('directory active orphan')
  const miniFatSectors = chain(u32(60), fat, owned, 'MiniFAT')
  if (miniFatSectors.length !== miniFatCount) damaged('MiniFAT sector 개수')
  const rootSectors = chain(root.start, fat, owned, 'mini stream FAT')
  if (root.size > rootSectors.length * sectorBytes) damaged('mini stream 크기')
  const miniCount = Math.ceil(root.size / miniBytes), miniFat = new Uint32Array(miniFatSectors.length * words)
  if (miniCount > miniFat.length) damaged('MiniFAT 크기')
  for (let index = 0; index < miniFatSectors.length; index++) for (let word = 0; word < words; word++) {
    const id = index * words + word, value = u32(offset(miniFatSectors[index]!) + word * 4)
    if (id >= miniCount && value !== free) damaged('MiniFAT 파일 밖 allocation')
    if (value !== free && value !== end && value >= miniCount) damaged('MiniFAT 범위')
    miniFat[id] = value
  }
  checkCycles(miniFat, miniCount, 'MiniFAT')
  const miniOwned = new Uint8Array(miniCount), result: CompoundEntry[] = []
  for (const location of order) {
    const entry = entries[location.id]!
    if (entry.type === 1) { result.push({ ...location, name: entry.name, kind: 'storage' }); continue }
    const small = entry.size < miniCutoff
    if (entry.size === 0) {
      if (entry.start !== end) damaged('빈 stream 시작 sector')
      result.push({ ...location, name: entry.name, kind: 'stream', size: 0, allocation: 'mini', sectors: [] }); continue
    }
    const sectors = chain(entry.start, small ? miniFat : fat, small ? miniOwned : owned, small ? 'mini stream' : 'stream FAT')
    let remaining = entry.size
    for (const id of sectors) {
      const needed = Math.min(small ? miniBytes : sectorBytes, remaining)
      if (small && id * miniBytes + needed > root.size) damaged('stream 크기와 chain 길이')
      remaining -= needed
    }
    if (remaining !== 0) damaged('stream 크기와 chain 길이')
    result.push({ ...location, name: entry.name, kind: 'stream', size: entry.size, allocation: small ? 'mini' : 'fat', sectors })
  }
  for (let id = 0; id < miniCount; id++) if (miniFat[id] !== free && !miniOwned[id]) damaged('MiniFAT active orphan')
  for (let id = 0; id < count; id++) if (fat[id] !== free && !owned[id]) damaged('FAT active orphan')
  return { sectorBytes, miniSectorBytes: miniBytes, miniStreamSectors: rootSectors, rootName: root.name, entries: result }
}
