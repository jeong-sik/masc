# TRPG Subsystem (Archived)

Archived as part of MASC to OAS migration Phase 0.
These modules implement a tabletop RPG game engine that was experimental.

To restore: move files back to `lib/` (and tests to `test/`), add modules to `lib/dune`, and re-enable references in dispatch/config/routes.
Git history is preserved via `git mv`.

## Library modules (from lib/)

- `trpg_*.ml` / `.mli` -- Core TRPG engine (types, store, rules, handlers, round logic, BDI, harness)
- `server_trpg_rest*.ml` -- HTTP REST API layer for TRPG
- `server_routes_http_routes_trpg.ml` -- HTTP/1.1 route registration
- `tool_trpg.ml` -- MCP tool dispatch
- `tool_protocol_game_view*.ml` -- Protocol gateway (decision/trpg/client domains)
- `game_view_state.ml` -- Game view state management

## Test modules (from test/)

- `test_trpg_*.ml` -- Unit and integration tests
- `test_protocol_game_view.ml` -- Protocol gateway tests
- `test_tool_trpg_coverage.ml` -- Tool coverage tests
- `test_narrative_intelligence.ml` -- Narrative intelligence tests (TRPG-dependent)

## Archived: 2026-03-18
