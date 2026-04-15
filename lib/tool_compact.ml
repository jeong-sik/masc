(** Tool_compact — Standalone MCP tool for context compaction.

    masc_compact_context removed: pruned from surfaces.

    @since 2.95.0 — Issue #1441 *)

(* All schemas removed — tool pruned *)
let schemas : Types.tool_schema list = []

type tool_result = bool * string

let dispatch ~name:_ ~args:_ : tool_result option = None
