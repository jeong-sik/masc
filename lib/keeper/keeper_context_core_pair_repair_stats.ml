(** Tool-pair repair stats and metadata helpers.

    Counters and message-metadata bookkeeping for the
    [repair_*_tool_*] family in [Keeper_context_core]. The repair
    bodies themselves stay in the parent (they depend on the
    parent's [tool_result_text_of_block] specialization, which
    closes over the parent's
    [default_max_checkpoint_tool_result_chars] constant).

    Pure record / metadata helpers — no parent-local state, no I/O,
    no callback injection. *)

type tool_pair_repair_stats =
  { downgraded_tool_uses : int
  ; downgraded_tool_results : int
  }

let empty_tool_pair_repair_stats =
  { downgraded_tool_uses = 0; downgraded_tool_results = 0 }

let add_tool_pair_repair_stats left right =
  { downgraded_tool_uses =
      left.downgraded_tool_uses + right.downgraded_tool_uses
  ; downgraded_tool_results =
      left.downgraded_tool_results + right.downgraded_tool_results
  }

let tool_pair_repair_stats_changed stats =
  stats.downgraded_tool_uses > 0 || stats.downgraded_tool_results > 0

let pair_repair_metadata_key = "masc.tool_pair_repair"

let pair_repair_metadata_keys =
  [ "was_fabricated"; "fabrication_source"; pair_repair_metadata_key ]

let with_pair_repair_metadata ~kind ~count (msg : Agent_sdk.Types.message) =
  let metadata =
    List.filter
      (fun (key, _) -> not (List.mem key pair_repair_metadata_keys))
      msg.metadata
  in
  { msg with
    metadata =
      [ "was_fabricated", `Bool true
      ; "fabrication_source", `String "tool_pair_repair"
      ; ( pair_repair_metadata_key
        , `Assoc
            [ "version", `Int 1
            ; "kind", `String kind
            ; "count", `Int count
            ] )
      ]
      @ metadata
  }
