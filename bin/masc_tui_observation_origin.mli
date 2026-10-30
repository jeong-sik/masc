(** Immutable provenance for one TUI instance and an original workspace read.
    This is observation metadata, never workspace/action authority. *)
type instance
val create_instance : id:string -> client_version:string -> instance
(** Inputs come from the existing UUID producer and linked build-version owner
    at the TUI lifetime boundary. No clock, entropy or I/O is performed here. *)
type t
val capture : instance -> expected_workspace:Masc.Tui_decode.server_identity -> t
val instance_id : t -> string
(** The original captured process identity, without decoding serialized facts. *)
val to_json : t -> Yojson.Safe.t
(** Prepare the immutable JSON once at read admission. Server version/commit are
    the identity observed at admission, not proof of which binary later served
    the response. Client version is reported metadata, not a source commit.
    No MCP session credential, question/answer body or error detail is included. *)
