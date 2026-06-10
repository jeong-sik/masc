#!/usr/bin/env node
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "..", "..", "..");

const requiredArtifacts = [
  "dashboard/design-system/source_styles/tokens.generated.css",
  "dashboard/src/styles/tokens.generated.css",
  "dashboard/src/styles/tokens.generated.ts",
  "dashboard_bonsai/src/tokens.ml",
  "dashboard_bonsai/src/tokens.mli",
  "dashboard/design-system/tokens/build/tokens.json",
  "dashboard_bonsai/static/colors_and_type.generated.css",
];

const missing = requiredArtifacts.filter((rel) => !existsSync(resolve(repo, rel)));

if (missing.length > 0) {
  console.error("tokens:build compatibility check failed; missing generated artifacts:");
  for (const rel of missing) {
    console.error(`  - ${rel}`);
  }
  process.exit(1);
}

console.log("tokens:build compatibility check passed; generated artifacts are checked in.");
