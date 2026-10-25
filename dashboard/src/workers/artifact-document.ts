import { Buffer } from 'node:buffer'
import { runArtifactDocumentCommand } from '../lib/artifact-document-command'

const chunks: Buffer[] = []
for await (const chunk of process.stdin) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
let response
try {
  const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(Buffer.concat(chunks))
  response = runArtifactDocumentCommand(JSON.parse(text))
} catch { response = { ok: false, code: 'invalid_request', message: 'expected a UTF-8 JSON artifact document command' } }
process.stdout.write(JSON.stringify(response) + '\n')
if (!response.ok) process.exitCode = 2
