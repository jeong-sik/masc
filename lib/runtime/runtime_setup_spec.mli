(** Shared typed first-run connection specification. Pure parsing/rendering;
    authentication, discovery and verification remain separate operations.
    Native rendering is the identity authority for new connections. Callers must
    consume its ID before choosing/defaulting a new connection, rather than
    reimplement JSON canonicalization. Existing declared IDs remain unchanged. *)
type t
type choice = Ollama | Llama_cpp | Vllm | Openai_compatible | Messages | Claude_code | Codex | Antigravity
val choice_name : choice -> string
(** The "choice" spelling [of_json] reads back. *)
val http : choice -> bool
(** HTTP endpoint connections; the others are product client commands. *)
type error = Invalid_spec of string
val error_message : error -> string
val of_json : ?home_dir:string -> Yojson.Safe.t -> (t, error) result
(** [home_dir] resolves an explicit current-user [~/] Antigravity reference;
    ordinary HTTP File references must already be absolute. No files are read. *)
type rendered = { runtime_id:string; runtime_toml:string; model_overlay_toml:string }
val model_id : t -> string
val render : t -> rendered
val librarian_lane_toml : cli:bool -> runtime_id:string -> string
(** The one-shot [runtime.exact_output_lanes.librarian_exact] declaration for
    the runtime a setup just verified. Emitted by the batch once per
    configure, never per spec: the table path is fixed, so per-spec emission
    writes the table once per added connection and the file stops parsing.
    [cli] selects [cli_slots] over [slots]. *)
val is_client_transport : t -> bool
(** Whether the spec connects through an official client command rather than
    an HTTP endpoint; exact-output lane admission keys differ between the two. *)
val render_json : rendered -> Yojson.Safe.t
(** Private native CLI/Python ABI only: TOML may contain credential paths.
    Web receipts must project only safe runtime/model identities. *)
