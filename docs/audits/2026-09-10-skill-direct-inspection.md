# Read Skill instructions from the catalog

Previously, opening a Skill row exposed its execution flow and evidence panel;
reading the actual instructions required another click on `Edit source`.
The catalog row now says `Read instructions` and loads the exact published
SKILL.md in a read-only inspector immediately when expanded.

The inspector uses the existing revision-bound `/api/v1/skills/editor/read`
API. It renders source text literally, including frontmatter, displays the
returned revision and access state, and refuses a different returned reference.
Loading, unavailable source, and retry are explicit. Late responses cannot
replace a newly selected revision. Existing editing remains a separate action.

Validation: the two focused Vitest suites passed 32 tests, including direct
catalog-row inspection, exact source text, revision changes, mismatch refusal
and failure/retry. No local build was run. CI asset build and browser evidence
are still required before claiming the deployed UI is changed.
