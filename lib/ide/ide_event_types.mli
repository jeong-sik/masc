(** IDE Event Types — unified event model for Keeper activity visualization.

    Captures tool call outcomes, PR operations, comments, and turn context
    as structured events that flow from the Keeper/Tool layer to the IDE layer. *)

(** {1 Event Variants} *)

type ide_event =
  | Region_event of region_event
  | Tool_event of tool_event
  | Pr_event of pr_event
  | Comment_event of comment_event
  | Turn_event of turn_event

and region_event =
  { file_path : string
  ; line_start : int
  ; line_end : int
  ; keeper_id : string
  ; tool_name : string
  ; turn_id : string
  ; outcome : string
  ; timestamp_ms : int64
  }

and tool_event =
  { tool_name : string
  ; keeper_id : string
  ; turn_id : string
  ; outcome : string
  ; typed_outcome : string
  ; latency_ms : int
  ; summary : string
  ; file_path : string option
  ; timestamp_ms : int64
  }

and pr_event =
  { pr_number : int
  ; pr_url : string
  ; pr_title : string
  ; pr_state : string
  ; repo : string
  ; keeper_id : string
  ; turn_id : string
  ; comment_count : int
  ; review_status : string option
  ; timestamp_ms : int64
  }

and comment_event =
  { comment_id : string
  ; pr_number : int option
  ; board_post_id : string option
  ; author : string
  ; content : string
  ; keeper_id : string
  ; turn_id : string
  ; timestamp_ms : int64
  }

and turn_event =
  { turn_id : string
  ; keeper_id : string
  ; phase : string
  ; model_used : string option
  ; tools_used : string list
  ; stop_reason : string option
  ; duration_ms : int option
  ; timestamp_ms : int64
  }

(** {1 JSON Serialization} *)

val ide_event_to_json : ide_event -> Yojson.Safe.t
val ide_event_to_string : ide_event -> string
