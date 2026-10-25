import { createHash } from 'node:crypto'
import { constants, type BigIntStats } from 'node:fs'
import { lstat, open, readdir, realpath } from 'node:fs/promises'
import { join, relative, resolve, sep } from 'node:path'

export type SiteFile = { path: string; bytes: number; sha256: string; content_base64: string }
export type SiteOutput = { kind: 'site'; entry_html: string; sha256: string; files: SiteFile[] }
const sha = (value: string | Uint8Array) => createHash('sha256').update(value).digest('hex')

// Capture the actual static output graph without rewriting HTML, module URLs,
// CSS, split chunks or runtime fetch paths. The result is data, never a program
// that the server/Dashboard should execute during import.
export async function collectSite(source: string, directory: string, entry: string): Promise<SiteOutput> {
  source = await realpath(source)
  const root = join(source, directory), actual = await realpath(root), rel = relative(source, actual)
  if (!rel || rel === '..' || rel.startsWith('..' + sep) || actual !== resolve(root) || !(await lstat(root)).isDirectory()) throw new Error('Build output must be a real directory inside the project')
  const files: SiteFile[] = []
  const observations: { path: string; stat: BigIntStats; entries?: string[] }[] = []
  const same = (a: BigIntStats, b: BigIntStats) => a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeNs === b.mtimeNs && a.ctimeNs === b.ctimeNs

  async function walk(parent: string, prefix: string): Promise<void> {
    const stat = await lstat(parent, { bigint: true })
    if (!stat.isDirectory() || await realpath(parent) !== resolve(parent)) throw new Error('Build output directory changed')
    const entries = await readdir(parent, { withFileTypes: true })
    entries.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)
    observations.push({ path: parent, stat, entries: entries.map(entry => entry.name) })
    for (const child of entries) {
      if (child.name.includes('\\')) throw new Error('Build output paths must use URL-compatible file names')
      const path = prefix + child.name, target = join(parent, child.name), observed = await lstat(target, { bigint: true })
      if (observed.isSymbolicLink()) throw new Error(`Build output contains a symbolic link: ${path}`)
      if (await realpath(target) !== resolve(root, path)) throw new Error(`Build output path changed: ${path}`)
      if (observed.isDirectory()) await walk(target, path + '/')
      else if (observed.isFile()) {
        const file = await open(target, constants.O_RDONLY | constants.O_NOFOLLOW)
        try {
          const before = await file.stat({ bigint: true })
          if (!before.isFile() || before.dev !== observed.dev || before.ino !== observed.ino) throw new Error(`Build output changed before reading: ${path}`)
          const bytes = await file.readFile(), after = await file.stat({ bigint: true }), current = await lstat(target, { bigint: true })
          if (before.size !== after.size || before.mtimeNs !== after.mtimeNs || before.ctimeNs !== after.ctimeNs
            || current.dev !== before.dev || current.ino !== before.ino || await realpath(target) !== resolve(root, path)) throw new Error(`Build output changed while reading: ${path}`)
          observations.push({ path: target, stat: after })
          files.push({ path, bytes: bytes.length, sha256: sha(bytes), content_base64: bytes.toString('base64') })
        } finally { await file.close() }
      } else throw new Error(`Build output is not a regular file or directory: ${path}`)
    }
  }
  await walk(root, '')
  // Revalidate the entire observed graph. A build that leaves a writer behind
  // must not silently mix an early file with later changes or omit a new chunk.
  for (const observation of observations) {
    const current = await lstat(observation.path, { bigint: true })
    if (!same(observation.stat, current) || await realpath(observation.path) !== resolve(observation.path)) throw new Error('Build output graph changed while collecting')
    if (observation.entries) {
      const entries = (await readdir(observation.path)).sort()
      if (entries.length !== observation.entries.length || entries.some((name, index) => name !== observation.entries![index])) throw new Error('Build output directory entries changed while collecting')
    }
  }
  const html = files.find(file => file.path === entry)
  if (!html) throw new Error('Build output does not contain the requested HTML entry')
  new TextDecoder('utf-8', { fatal: true }).decode(Buffer.from(html.content_base64, 'base64'))
  if (await realpath(root) !== actual) throw new Error('Build output directory changed while collecting')
  const manifest = { entry_html: entry, files: files.map(({ path, bytes, sha256 }) => ({ path, bytes, sha256 })) }
  return { kind: 'site', ...manifest, files, sha256: sha(JSON.stringify(manifest)) }
}
