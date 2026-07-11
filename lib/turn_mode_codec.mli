(** Pure codec for the [turn_mode] enum and its [work_kind] projection.

    Extracted from [Keeper_unified_metrics_support] (RFC-0182 §3.1 cycle
    break audit, 2026-05-27): the previous owner module lived in
    [lib/keeper], which created a [Tool_agent_timeline -> Keeper_*] back
    edge through [work_kind_of_json]. That back edge formed a dependency
    cycle when [Keeper_tool_in_process_runtime] (in [lib/keeper]) tried
    to call [Tool_misc.dispatch] /
    [Tool_agent_timeline.dispatch] through descriptor projection.

    Moving the pure parsing helpers into [lib] (above [lib/keeper] in
    the dependency graph) is sufficient to dissolve the cycle. The
    semantic functions in [Keeper_unified_metrics_support] continue to
    live in [lib/keeper] and re-use these primitives. *)

type turn_mode =
  | Tool_use
  | Text_response
  | Skip_text
  | Noop

val turn_mode_to_string : turn_mode -> string
val turn_mode_of_string : string -> turn_mode option

val work_kind_of_turn_mode : turn_mode -> string
(** Returns the broader "work kind" bucket for a turn mode:
    [Tool_use -> "tool_use"], [Noop -> "noop"],
    [Text_response | Skip_text -> "text_turn"]. *)

val turn_mode_of_json : Yojson.Safe.t -> turn_mode option
(** Reads [turn_mode] or [selected_mode] string fields from the JSON
    payload, falling back to a legacy [work_kind] field for backwards
    compatibility with older keeper turn records. *)

val work_kind_of_json : Yojson.Safe.t -> string option
(** First tries [turn_mode_of_json] then projects via
    [work_kind_of_turn_mode]; falls back to a literal [work_kind]
    string when no typed mode is present. Empty strings are rejected. *)
