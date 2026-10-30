import { buildProject, ProjectError } from './project.ts'
const chunks: Buffer[] = []
for await (const chunk of process.stdin) chunks.push(Buffer.from(chunk))
try {
  if (process.argv.length !== 4 || process.argv[2] !== '--workspace') throw new ProjectError('input', 'Usage: node src/cli.ts --workspace <existing lane directory>')
  let request: unknown
  try { request = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks))) }
  catch { throw new ProjectError('input', 'Expected UTF-8 JSON project request') }
  process.stdout.write(JSON.stringify({ ok: true, result: await buildProject(request, process.argv[3]) }) + '\n')
} catch (error) {
  process.stdout.write(JSON.stringify({ ok: false, stage: error instanceof ProjectError ? error.stage : 'build', run_directory: error instanceof ProjectError ? error.run_directory : null, message: error instanceof Error ? error.message : String(error) }) + '\n')
  process.exitCode = 2
}
