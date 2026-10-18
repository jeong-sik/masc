#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { renderDiagram } from './engine.mjs';

if (process.argv.length === 3 && process.argv[2] === '--help') {
  console.log('masc-pele: read {source,maxWidth,colors?} JSON from stdin; write PNG to stdout');
} else {
  try {
    const result = renderDiagram(JSON.parse(readFileSync(0, 'utf8')));
    process.stdout.write(result.png);
  } catch (error) {
    // Errors can contain untrusted source. Emit plain diagnostics only on stderr.
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
