(** Fixed offline commands under the configured host BasePath lease. No live
    Board store is admitted. Inspection never reads host lease configuration. *)
type response

val inspect : base_path:string -> response
val bootstrap : base_path:string -> expected_intent_sha256:string -> response
val adopt : base_path:string -> expected_intent_sha256:string -> response
val response_to_yojson : response -> Yojson.Safe.t
val exit_code : response -> int
(** Uses the Board decision/completion, never rendered JSON. *)
val finish : response -> unit
(** Pure: propagate retained original reserved Board evidence before unexpected
    adapter/release evidence. Release is attempted, never certified. *)
