(** Neutral runtime observation bus for agent activity.

    Producers in Keeper/Tooling emit here without depending on any UI/IDE
    storage module. Consumers register process-local sinks that translate
    these neutral records into their own persistence or streaming surfaces. *)

type tool_event =
  { base_path : string
  ; tool_name : string
  ; keeper_id : string
  ; turn_id : string
  ; outcome : string
  ; typed_outcome : string
  ; duration_ms : float
  ; output_text : string
  ; input : Yojson.Safe.t
  }

type pr_event =
  { base_path : string
  ; keeper_id : string
  ; turn_id : string
  ; output_text : string
  ; tool_name : string
  ; success : bool
  }

type turn_event =
  { base_path : string
  ; turn_id : string
  ; keeper_id : string
  ; phase : string
  ; model_used : string option
  ; tools_used : string list
  ; stop_reason : string option
  ; duration_ms : int option
  ; timestamp_ms : int64
  }

type tool_event_sink = tool_event -> unit
type pr_event_sink = pr_event -> unit
type turn_event_sink = turn_event -> unit

val register_tool_event_sink : tool_event_sink -> unit
val register_pr_event_sink : pr_event_sink -> unit
val register_turn_event_sink : turn_event_sink -> unit

val emit_tool_event : tool_event -> unit
val emit_pr_event : pr_event -> unit
val emit_turn_event : turn_event -> unit

val reset_for_testing : unit -> unit
(** Reset sinks to no-op. Intended for isolated tests only. *)
