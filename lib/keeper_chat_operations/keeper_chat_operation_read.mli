(** A missing operation is an observation of one successful Keeper-owner lookup. *)
type absence = { keeper_name : string; operation_id : Keeper_operation_id.t }

val unknown_operation_code : string
val public_error_json :
  ?absence:absence -> code:string -> message:string -> incident_id:string -> unit -> Yojson.Safe.t
val confirms_absence : absence -> Yojson.Safe.t -> bool
