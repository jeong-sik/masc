(** Tool-effect decision evidence.

    A record in this module captures the enforcement decision for one tool
    attempt: what effect class was inferred, whether it was allowed or
    blocked, and enough metadata to join it with tool traces. *)

type effect_class =
  | Read_only
  | Local_mutation
  | External_effect
  | Shell_dynamic

type decision =
  | Allowed
  | Denied
  | Approval_required
  | Approved
  | Rejected
  | Edited
  | Skipped
  | Overridden

type result_status =
  | Pending
  | Succeeded
  | Failed
  | Not_run

type t =
  { schema_version : int
  ; tool_use_id : string
  ; tool_name : string
  ; effect_class : effect_class
  ; decision : decision
  ; decision_source : string
  ; input_hash : string
  ; input_summary : string
  ; sandbox : string option
  ; workdir : string option
  ; source_path : string option
  ; source_line : int option
  ; started_at : float
  ; ended_at : float option
  ; result_status : result_status
  ; violation_kind : string option
  ; turn : int option
  ; execution_mode : string option
  }

val schema_version_current : int
val effect_class_to_string : effect_class -> string
val effect_class_of_string : string -> (effect_class, string) result
val decision_to_string : decision -> string
val decision_of_string : string -> (decision, string) result
val result_status_to_string : result_status -> string
val result_status_of_string : string -> (result_status, string) result
val hash_input : Yojson.Safe.t -> string

val make
  :  ?schema_version:int
  -> ?input_hash:string
  -> ?input_summary:string
  -> ?sandbox:string
  -> ?workdir:string
  -> ?source_path:string
  -> ?source_line:int
  -> ?ended_at:float
  -> ?result_status:result_status
  -> ?violation_kind:string
  -> ?turn:int
  -> ?execution_mode:string
  -> tool_use_id:string
  -> tool_name:string
  -> effect_class:effect_class
  -> decision:decision
  -> decision_source:string
  -> input:Yojson.Safe.t
  -> started_at:float
  -> unit
  -> t

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
