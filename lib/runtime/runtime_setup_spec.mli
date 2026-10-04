(** Shared typed first-run connection specification. Pure parsing/rendering;
    authentication, discovery and verification remain separate operations.
    Native rendering is the identity authority for new connections. Callers must
    consume its ID before choosing/defaulting a new connection, rather than
    reimplement JSON canonicalization. Existing declared IDs remain unchanged. *)
type t
type choice = Ollama | Llama_cpp | Vllm | Openai_compatible | Messages | Claude_code | Codex | Antigravity | Muse
val choice_name : choice -> string
(** The "choice" spelling [of_json] reads back. *)
val http : choice -> bool
(** HTTP endpoint connections; the others are product client commands. *)
type error = Invalid_spec of string
val error_message : error -> string
val of_json : ?home_dir:string -> Yojson.Safe.t -> (t, error) result
(** [home_dir] resolves an explicit current-user [~/] Antigravity reference;
    ordinary HTTP File references must already be absolute. Claude Code,
    Codex and Muse accept an absolute [account_home]. Muse requires this
    selection. Account paths retain their exact spelling in the connection
    identity and rendered provider. Omission keeps ambient selection for Claude
    Code and Codex. Optional [supports_image_input] is an explicit boolean
    model declaration; omission leaves image support undeclared. No files are read. *)
type rendered = { runtime_id:string; runtime_toml:string }
val setup_exact_body_timeout_s : float
(** The [exact-body-timeout-s] setup writes on an HTTP provider it points the
    exact-output lanes at: on a connection it renders, and on an existing
    provider [--setup-lanes] selects that declares none (#38779). *)
val model_id : t -> string
val provider_id : t -> string
(** Connection identity, shared by every model and context variant using the
    same transport and account. Model declarations do not change it. *)
val for_provider : t -> Runtime_schema.provider -> t option
(** Reuse a parsed, configured provider only when its protocol, transport,
    credential and account selection match this specification. A new account
    reference or changed connection returns [None]. This is not a JSON field. *)
val render : ?include_provider:bool -> ?wizard_default:bool -> t -> rendered
(** [include_provider=false] appends a model to an already declared connection.
    [wizard_default=false] avoids adding a second installation default on that
    provider. Standalone rendering includes both declarations by default. *)
val render_json : rendered -> Yojson.Safe.t
(** Private native CLI/Python ABI only: TOML may contain credential paths.
    Web receipts must project only safe runtime/model identities. *)
