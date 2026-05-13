(** Shared IDE annotation and code-region wire types. *)

type annotation_kind =
  | Comment
  | Decision
  | Question
  | Bookmark

val annotation_kind_to_string : annotation_kind -> string
val annotation_kind_of_string : string -> annotation_kind option

type annotation =
  { id : string
  ; file_path : string
  ; line_start : int
  ; line_end : int
  ; keeper_id : string
  ; kind : annotation_kind
  ; content : string
  ; goal_id : string option
  ; task_id : string option
  ; created_at_ms : int64
  ; updated_at_ms : int64
  }

type code_region =
  { file_path : string
  ; line_start : int
  ; line_end : int
  ; keeper_id : string
  ; source : region_source
  ; timestamp_ms : int64
  }

and region_source =
  | Tool_call of
      { tool_name : string
      ; turn : int
      }
  | Manual of { note : string }

type annotation_filter =
  { file_path : string option
  ; keeper_id : string option
  ; goal_id : string option
  ; task_id : string option
  }

val annotation_to_json : annotation -> Yojson.Safe.t
val annotation_of_json : Yojson.Safe.t -> (annotation, string) result
val region_to_json : code_region -> Yojson.Safe.t
val region_of_json : Yojson.Safe.t -> (code_region, string) result
