(** Immutable, restart-reconstructable input for one post-turn Memory Lane unit. *)

type t

val schema_version : int
val request_id : t -> string
val keeper_name : t -> string
val generation : t -> int
val turn : t -> int
val runtime_id : t -> string
val meta : t -> Keeper_meta_contract.keeper_meta
val tool_results : t -> Yojson.Safe.t list
val librarian_messages : t -> Agent_sdk.Types.message list
val deliberation_execution : t -> Yojson.Safe.t option

val make :
  keeper_name:string ->
  generation:int ->
  turn:int ->
  runtime_id:string ->
  meta:Keeper_meta_contract.keeper_meta ->
  tool_results:Yojson.Safe.t list ->
  librarian_messages:Agent_sdk.Types.message list ->
  deliberation_execution:Yojson.Safe.t option ->
  (t, string) result
(** Validate the typed snapshot and derive [request_id] from its canonical JSON.
    The identifier is content-derived; it is not a scheduling limit or policy. *)

val to_json : t -> Yojson.Safe.t
val of_json : Yojson.Safe.t -> (t, string) result
(** Strict closed codec. Unknown or duplicate fields and identifier drift are
    explicit errors. *)
