(** Bounded observation registry for active and recently completed Fusion runs. *)

type outcome =
  | Succeeded
  | Failed of
      { reason : string
      ; code : string
      }

type run_status =
  | Running
  | Completed of outcome

type run =
  { run_id : string
  ; keeper : string
  ; preset : string
  ; started_at : float
  ; status : run_status
  }

type t

val create : ?path:string -> unit -> t
val replay : string -> t

val register_running
  :  t
  -> run_id:string
  -> keeper:string
  -> preset:string
  -> started_at:float
  -> unit

val mark_completed : t -> run_id:string -> outcome:outcome -> unit
(** Complete a registered run. An unknown [run_id] is logged and is not written
    to the append-only log. *)

val list_runs : t -> run list
val get : t -> run_id:string -> run option
val status_label : run_status -> string
val run_to_yojson : run -> Yojson.Safe.t
val global : unit -> t
val set_global : t -> unit
val max_completed_retained : int
