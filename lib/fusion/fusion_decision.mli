(** Keeper adoption of advice is recorded in the existing task event journal. *)
type disposition = Adopted | Rejected | Modified
type recorded = { event : Yojson.Safe.t; cleanup_warning : string option }
type proposal
val parse : Yojson.Safe.t -> (proposal, string) result
val record : config:Workspace.config -> keeper:string -> turn_ref:Ids.Turn_ref.t ->
  proposal -> (recorded, string) result
val read : config:Workspace.config -> run_id:string -> (Yojson.Safe.t list, string) result
val read_for_keeper : config:Workspace.config -> keeper:string -> run_id:string ->
  (Yojson.Safe.t list, string) result
val read_to_yojson : (Yojson.Safe.t list, string) result -> Yojson.Safe.t
