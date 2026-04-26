(** Drift Guard - truthful handoff integrity verification.

    This module owns the similarity and verdict logic for handoff verification.
    MCP surfaces should call into this module instead of keeping private
    copies in transport/server code.
*)

type weights =
  { jaccard : float
  ; cosine : float
  }

type drift_type =
  | Semantic
  | Factual
  | Structural
  | None

type verification_summary =
  { similarity : float
  ; jaccard : float
  ; cosine : float
  ; threshold : float
  }

type drift_details =
  { similarity : float
  ; jaccard : float
  ; cosine : float
  ; threshold : float
  ; drift_type : drift_type
  }

type verification_result =
  | Verified of verification_summary
  | Drift_detected of drift_details

val drift_type_to_string : drift_type -> string
val drift_type_of_string : string -> drift_type
val weights : unit -> weights
val tokenize : string -> string list
val jaccard_similarity : string list -> string list -> float
val cosine_similarity : string list -> string list -> float
val text_similarity : string -> string -> float

val verify_handoff
  :  original:string
  -> received:string
  -> ?threshold:float
  -> unit
  -> verification_result

val result_to_json : verification_result -> Yojson.Safe.t
val drift_log_file : Coord.config -> string

val verify_and_log
  :  Coord.config
  -> from_agent:string
  -> to_agent:string
  -> task_id:string
  -> original:string
  -> received:string
  -> ?threshold:float
  -> unit
  -> verification_result

val get_drift_stats : Coord.config -> days:int -> int * int * float
