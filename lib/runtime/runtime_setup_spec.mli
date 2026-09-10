(** Shared typed first-run connection specification. Pure parsing/rendering;
    authentication, discovery and verification remain separate operations.
    Native rendering is the identity authority for new connections. Callers must
    consume its ID before choosing/defaulting a new connection, rather than
    reimplement JSON canonicalization. Existing declared IDs remain unchanged. *)
type t
type error = Invalid_spec of string
val error_message : error -> string
val of_json : ?home_dir:string -> Yojson.Safe.t -> (t, error) result
(** [home_dir] resolves an explicit current-user [~/] Antigravity reference;
    ordinary HTTP File references must already be absolute. No files are read. *)
type rendered = { runtime_id:string; runtime_toml:string; model_overlay_toml:string }
val render : t -> rendered
val render_json : rendered -> Yojson.Safe.t
(** Private native CLI/Python ABI only: TOML may contain credential paths.
    Web receipts must project only safe runtime/model identities. *)
