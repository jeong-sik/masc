#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { renderDocument } from './engine.mjs';

if (process.argv.length === 3 && process.argv[2] === '--help') {
  console.log('masc-pele: read {format:mermaid|svg,source,maxWidth,colors?} JSON from stdin; write PNG to stdout');
} else {
  try {
    const result = renderDocument(JSON.parse(readFileSync(0, 'utf8')));
    process.stdout.write(result.png);
  } catch (error) {
    // Errors can contain untrusted source. Emit plain diagnostics only on stderr.
    const diagnostic = error.message.replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g,
      value => `\\u${value.charCodeAt(0).toString(16).padStart(4, '0')}`);
    process.stderr.write(`${diagnostic}\n`);
    process.exitCode = 1;
  }
}
