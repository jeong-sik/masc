(** Mutable shared-source documents, distinct from immutable publications. *)
type target = { artifact_id : string; generation : string }
type selection = { target : target; position : Artifact_document_engine.selection }
type t = private
  { target : target; base_revision : int; base_sha256 : string; state : string
  ; sequence : int; updated_by : string; updated_at : string }
type command =
  | Open of { artifact_id : string; revision : int }
  | Merge of { target : target; updates : string list }
  | Select of { target : target; anchor : int; head : int }
  | Edit of { selection : selection; expected : string; replacement : string }

val create : target:target -> base_revision:int -> base_sha256:string ->
  state:string -> actor:string -> at:string -> (t, string) result
val advance : t -> state:string -> actor:string -> at:string -> (t, string) result
val of_json : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val target_to_json : target -> Yojson.Safe.t
val selection_to_json : selection -> Yojson.Safe.t
val command_of_json : Yojson.Safe.t -> (command, string) result
