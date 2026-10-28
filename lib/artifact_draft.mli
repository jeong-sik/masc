(** Mutable shared-source documents, distinct from immutable publications. *)
type target = { artifact_id : string; generation : string }
type selection = { target : target; position : Artifact_document_engine.selection }
type t = private
  { target : target; base_revision : int; base_sha256 : string; state : string
  ; sequence : int; updated_by : string; updated_at : string; discussion : Artifact_discussion.event list }
type command =
  | Open of { artifact_id : string; revision : int }
  | Merge of { target : target; updates : string list }
  | Select of { target : target; anchor : int; head : int }
  | Resolve of selection
  | Edit of { selection : selection; expected : string; replacement : string }
  | Discuss of { target : target; request : Artifact_discussion.request }

val create : target:target -> base_revision:int -> base_sha256:string ->
  state:string -> actor:string -> at:string -> (t, string) result
val advance : ?discussion:Artifact_discussion.event list -> t -> state:string -> actor:string -> at:string -> (t, string) result
val checkpoint : t -> base_revision:int -> base_sha256:string -> actor:string -> at:string -> (t, string) result
(** Advance the publication base while retaining the exact CRDT state and
    discussion. The store must establish that the new publication matches the
    same observed draft before calling this constructor. *)
val of_json : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val public_to_json : t -> Yojson.Safe.t
val document_to_json : draft:t -> content:string -> selection:(selection * int * int) option -> Yojson.Safe.t
val target_to_json : target -> Yojson.Safe.t
val selection_to_json : selection -> Yojson.Safe.t
val target_of_json : Yojson.Safe.t -> (target, string) result
val command_of_json : Yojson.Safe.t -> (command, string) result
