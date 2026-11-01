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
    model declaration; omission leaves image support undeclared. HTTP [request_path]
    names a validated endpoint-relative surface; omission uses the protocol default.
    Private installer [existing_provider_id] is only a selection hint until
    [resolve_provider] checks that exact configured provider against the spec.
    Named HTTP catalog selections carry [provider_id], [provider_display_name],
    [model_key] and [provider_declared], with optional [reasoning_effort] and
    [wizard_default]. Their provider/model identity is retained by native
    rendering; [resolve_provider] admits an absent provider only when the
    selected catalog connection matches its endpoint, dialect and request path.
    Named selections require exact provider/model catalog membership, including
    when extending an existing named account. Ordinary custom connection and
    [existing_provider_id] specifications retain their separate admission rules.
    No files are read. *)
type rendered = { runtime_id:string; runtime_toml:string }
val setup_exact_body_timeout_s : float
(** The [exact-body-timeout-s] setup writes on an HTTP provider it points the
    exact-output lanes at: on a connection it renders, and on an existing
    provider [--setup-lanes] selects that declares none (#38779). *)
val model_id : t -> string
val provider_id : t -> string
(** Connection identity, shared by every model and context variant using the
    same transport and account. Model declarations do not change it. *)
val account_home_matches : choice -> string option -> string option -> bool
(** Compare the effective native account homes used by the official client.
    An omitted Claude/Codex home uses that client's environment/default rule. *)
val same_connection : t -> t -> bool
(** Compare protocol, endpoint/request surface and credential/account selection,
    independently of model, context and image capability. Native account homes
    use the same effective-home comparison as configured-provider reuse. *)
val same_selection : t -> t -> bool
(** Exact parsed selection identity, including model, context, image declaration,
    effort and named-provider metadata. Used before deduplicating a rendered
    runtime ID so a fixed named model key cannot discard a differing selection. *)
val for_provider : t -> Runtime_schema.provider -> t option
(** Reuse a parsed, configured provider only when its protocol, transport,
    credential, request surface and account selection match this specification,
    and it is enabled. CLI providers must also declare [is-non-interactive=true]. A new account
    reference or changed connection returns [None]. This is not a JSON field. *)
val for_existing_inline_provider : t -> Runtime_schema.provider -> t option
(** Explicitly reuse the selected HTTP provider's inline credential when the
    specification carries no replacement credential. Only a trusted caller
    selecting the existing account may call this; JSON cannot request it.
    Captures the provider ID and inline value for [resolve_provider] to compare
    again against the locked configuration. Never reads a credential file. *)
val resolve_provider : t -> Runtime_schema.provider list -> (t, error) result
(** Bind to the matching enabled configured account before rendering. Refuse
    disabled, interactive CLI or ambiguous accounts; never enable or overwrite
    a provider. A new named provider must match its exact catalog connection;
    a declaration that claims an existing provider cannot create one. *)
val render : ?include_provider:bool -> ?wizard_default:bool -> t -> rendered
(** [include_provider=false] appends a model to an already declared connection.
    [wizard_default=false] avoids adding a second installation default on that
    provider. Standalone rendering includes both declarations by default;
    a named selection of an existing provider defaults to model/binding only.
    Existing-inline selections always render only the model and binding: their
    original provider block remains authoritative and its secret is not exported. *)
val matches_existing_selection : t -> Runtime_schema.config -> bool
(** A supplied named selection whose rendered ID is already saved must match
    its saved model, tool/stream support, image declaration, effort and binding
    context. Missing named IDs and generated selections remain eligible for the
    ordinary add/reuse path. Unspecified operator settings are not overwritten. *)
val render_json : rendered -> Yojson.Safe.t
(** Private native CLI/Python ABI only: TOML may contain credential paths.
    Web receipts must project only safe runtime/model identities. *)
