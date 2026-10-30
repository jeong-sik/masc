# Workspace curator prompt surface

The prompt registry now selects Librarian by its exact prompt key and shows a
separate Workspace Curator contract. Both prompts share the librarian category;
category-first lookup could bind the Librarian card to the curator when ordering
changed or the Librarian key was absent. The new card identifies original source
inventory, metadata/gaps, explicit lane configuration, successful-input reuse,
model-proposed status and the exact prompt editor action.

Fourteen mounted tests pass, including curator-first ordering, opening its exact
override without saving, and missing Librarian without substitution. Whole
Dashboard TypeScript and the three changed TS files' ESLint passed. The final
source-browser probe renders the real component with synthetic API data, opens
both templates, checks absent-Librarian behavior, verifies no HTTP writes, and
captures desktop/mobile cards with no page errors or horizontal overflow.
The mobile image was directly inspected. Receipt hashes identify the component.

The first browser run failed with a hook error while the Vite development server
reported new dependency optimization/reloading. Its failure is preserved. A fresh
browser after dependency preparation passed; this does not establish an installed
runtime regression or an independent general fix for the development environment.
No production Dashboard or local native build ran.

These are source UI results. They do not prove a native curator run, configured
model admission, installed prompt publication, or Keeper adoption. The card names
selected slots because the existing run view does not independently prove the
resolved provider/model identity.
