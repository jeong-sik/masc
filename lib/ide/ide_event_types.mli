(** IDE Event Types — unified event model for Keeper activity visualization. *)

type ide_event =
  | Tool_event of tool_event
  | Turn_event of turn_event
  | Pr_event of pr_event

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

val ide_event_to_json : ide_event -> Yojson.Safe.t
