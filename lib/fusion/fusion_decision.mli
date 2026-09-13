(** Keeper adoption of advice is recorded in the existing task event journal. *)
type disposition = Adopted | Rejected | Modified
type error = Rejected of string | Storage_failure of string
val error_to_string : error -> string
val failure_class : error -> Tool_result.tool_failure_class
(** Canonical Board-origin lookup, scoped to the originating Keeper. It does
    not depend on retention of the run registry entry. *)
val source : keeper:string -> run_id:string -> (Board.post, error) result
val evidence_sha256 : Board.post -> string

type recorded = { event : Yojson.Safe.t; cleanup_warning : string option }
type proposal
val parse : Yojson.Safe.t -> (proposal, string) result
val record : config:Workspace.config -> keeper:string -> turn_ref:Ids.Turn_ref.t ->
  proposal -> (recorded, error) result
val read : config:Workspace.config -> run_id:string -> (Yojson.Safe.t list, error) result
val read_for_keeper : config:Workspace.config -> keeper:string -> run_id:string ->
  (Yojson.Safe.t list, error) result
val read_to_yojson : (Yojson.Safe.t list, error) result -> Yojson.Safe.t
