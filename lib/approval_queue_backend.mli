(** Approval queue bridge consumed by inline tools. *)

val list_pending_json : unit -> Yojson.Safe.t
val get_pending_json : id:string -> Yojson.Safe.t option

val resolve :
  id:string ->
  decision:Agent_sdk.Hooks.approval_decision ->
  (unit, string) result
