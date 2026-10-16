(** Shared, typed ownership coordinates for the job journal and its completion
    queue. This module contains no backend or delivery effects. *)
module Job_id : sig
  type t
  val fresh : unit -> t
  val of_string : string -> (t, string) result
  val to_string : t -> string
end

type source =
  { task_id : string option
  ; turn_ref : Ids.Turn_ref.t option
  ; tool_use_id : string option
  ; trace_id : string option
  ; keeper_turn_id : int option
  }

val source_to_json : source -> Yojson.Safe.t
val source_of_json : Yojson.Safe.t -> (source, string) result
(** Exact fields, no aliases, duplicate keys or implicit source context. *)
