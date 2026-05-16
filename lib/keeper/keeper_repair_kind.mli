(** Keeper_repair_kind — closed sum naming the two silent fabrications
    performed by [Keeper_context_core.repair_broken_tool_call_pairs] when
    Anthropic's tool_use/tool_result pairing invariant is violated after
    compaction/cap/rollover.

    These fabrications used to be invisible (no log, no metric); they run on
    every compaction via [Keeper_compact_policy] and on every retry, so the
    operational signal for "context reducer dropped the matching half of a
    tool pair" was lost. This module gives each fabrication a stable label
    so the [Prometheus] counter and [Log.Keeper] line keep typed contracts
    instead of free-form strings.

    Adding a new repair flavour MUST extend this type — exhaustive [match]
    in [to_label] is the design intent. *)

type t =
  | Dangling_tool_use
      (** A [ToolUse] block had no matching [ToolResult] in the next message;
          we downgraded it to plain [Text] to keep the trail without
          replaying tool metadata.  Emitted from
          [Keeper_context_core.repair_dangling_tool_use_messages]. *)
  | Orphan_tool_result
      (** A [ToolResult] block referenced a [tool_use_id] absent from the
          previous message; we downgraded it to plain [Text] so the
          semantic output survives without triggering Anthropic's
          pairing validation.  Emitted from
          [Keeper_context_core.repair_orphan_tool_result_messages]. *)

val to_label : t -> string
