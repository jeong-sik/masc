### Fixed

- TUI: the frame the server sends once a skill node's call-log row is
  committed (`keeper_tool_call_evidence_committed`) decodes into its own
  event. Its Activity row names the Keeper, the node's tool, the skill tool
  and the node instead of `server` and an empty detail. It draws under
  Everything only, since the node's call already has its own
  `keeper_tool_call` row. The Keeper calls view reads again when it lands.
  A frame missing a field the server always writes, or carrying a run id or
  node id that does not parse, is undecodable rather than shown as an
  unknown type. A type the TUI was not taught draws without an author
  instead of `server` (#38884, #PENDING).
