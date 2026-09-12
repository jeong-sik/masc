import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

if (process.argv.length !== 3) throw new Error('Usage: node read-state.mjs STATE.BIN');
const bytes = await readFile(process.argv[2]);
if (bytes.length !== 8 || bytes.subarray(0, 4).toString('ascii') !== 'LANE' || bytes.readUInt16LE(4) !== 1) {
  throw new Error('Not a LANE version 1 state artifact');
}
console.log(JSON.stringify({ format: 'LANE', version: 1, counter: bytes.readUInt16LE(6),
  sha256: createHash('sha256').update(bytes).digest('hex') }));
