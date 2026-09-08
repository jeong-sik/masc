# Keeper prompt simplification

The shared instructions have Korean and English editions. The editor loads a
shipped edition into the draft; the existing save operation writes only `keeper`.
Runtime frames remain shared. Roles contain only role-specific work, and browser
procedures stay in the existing browser-lanes skill.

This follows the small, relevant context approach described in
[Anthropic's context engineering article](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents).
The reduction in bytes is measured; improved model behavior is not yet measured.

## Evidence (2026-09-08)

- Existing deployed runtime: 0.34.0, port 8935; full health resolved the base path
  to `/Users/dancer/me` and runtime root to `/Users/dancer/me/.masc`.
- Live `keeper` override: 9,893 → 4,200 UTF-8 bytes. Existing contents were backed
  up under the runtime's `backups/` directory before applying through authenticated
  `POST /api/v1/prompts`. A fresh GET matched the new body exactly; see
  [runtime.json](runtime.json). This proves registry state, not a model turn.
- Nine role instruction bodies: 10,255 → 4,712 UTF-8 bytes. Parsed TOML settings
  other than `instructions` are identical to the original files.
- Prompt editor and assembly tests: 18 passed. TypeScript typecheck passed with
  the lockfile's installed dependencies. No local Dune build was run.
- Headless Chromium rendered the real PromptRegistryPanel with mocked prompt HTTP
  responses and the actual new language bodies. English selection made no write;
  Save sent the English body under `keeper`; Korean selection and Save restored
  the Korean body. [Screenshot](language-preview.png) shows the English draft.
  This is isolated UI evidence, not a screenshot of the deployed dashboard.

The new editor and bundled English asset still require release deployment.
Individual role presets and technical runtime frames have not been translated
into a second locale. Existing custom role instructions are operator-owned and
are not overwritten by the release. No model-behavior or long-running Keeper
quality comparison has been performed.
