# RFC-0006: Keeper Surface And Sandbox

- **Status**: Superseded
- **Author**: vincent (with Agent-LLM-A)
- **Created**: 2026-04-20
- **Superseded by**: `Agent_tool_descriptor` + sandbox boundary split

This RFC described an earlier alias-era design. It is intentionally retired:
the keeper-facing surface is now descriptor-owned, and model-facing names are
the hard-cut descriptor public names (`Execute`, `ReadFile`, `EditFile`,
`WriteFile`, `SearchFiles`, `SearchWeb`, `FetchWeb`).

The current rule is:

- `Agent_tool_descriptor` owns public name, input schema, policy projection,
  executor/backend/sandbox labels, runtime handler, and receipt evidence.
- Sandbox modules own containment/backend boundaries only.
- Shell IR remains a first-class parser/lowering layer under Execute; it is not
  a public product family.
- Historical provider built-in aliases are retired routing misses, not
  compatibility names.

Do not use this RFC as implementation guidance for new tool routing work.
