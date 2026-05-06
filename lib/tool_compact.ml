(** Tool_compact — OAS-backed compaction pipeline.

    masc_compact_context removed: pruned from surfaces.
    Compaction is now handled internally by OAS agent lifecycle.

    @since 2.95.0 — Issue #1441 *)

(* All schemas removed — tool pruned *)
let schemas : Masc_domain.tool_schema list = []

type tool_result = Tool_result.t

let dispatch ~name:_ ~args:_ : tool_result option = None
