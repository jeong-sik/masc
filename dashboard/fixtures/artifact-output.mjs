import { mkdir, mkdtemp } from 'node:fs/promises'
import { basename, dirname, join, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

export const dashboardRoot = fileURLToPath(new URL('../', import.meta.url))

// Captures are run output; fixture sources and committed evidence stay immutable.
export async function artifactDirectory(fixtureUrl, subdirectory = '') {
  const bundle = basename(dirname(fileURLToPath(fixtureUrl)))
  const parent = join(fileURLToPath(new URL('../../artifacts/dashboard/', import.meta.url)), bundle, subdirectory)
  await mkdir(parent, { recursive: true })
  const output = await mkdtemp(join(parent, 'run-'))
  console.log(`Fixture artifacts: ${output}`)
  return output + sep
}
