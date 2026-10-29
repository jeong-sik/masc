(** Declarative Runtime TOML parser (RFC-0206, runtime→Runtime rebirth).

    Re-homed from the deleted [Runtime_declarative_parser]. Parses only
    RFC-0058 layers 1-3 plus [\[runtime\].default] into a self-standing
    {!Runtime_schema.config}:

    - [\[providers.*\]] — Layer 1; unknown provider fields are rejected with
      their full TOML path
    - [\[models.*\]] — Layer 2
    - [<provider>.<model>] binding tables — Layer 3
    - [model_sets.<name>].models — shared model ids. A provider's
      [model-set] references one list, materializing its provider × model
      bindings. Explicit binding tables override the generated defaults.
    - [\[runtime\].default] — the default Runtime id ([provider.model])
    - [\[exec.ssh.endpoints.*\]] — SSH remote execution endpoint registry
      (Phase 1 SSH lane, spec §4.2); exposed as
      {!Runtime_schema.config.exec_ssh_endpoints}

    The routing layers are intentionally NOT parsed: Layer 4 aliases
    ([<p>.<m>.<a>]), Layer 5 [\[routes\]]/[\[system\]]/[\[profiles\]], and the
    strategy/cycle-policy/scoring tables are dropped. A Runtime is a single
    pre-selected (provider × model) binding, so there is no routing
    indirection to model. *)

type parse_error =
  { path : string  (** TOML path where the error occurred *)
  ; message : string
  }
[@@deriving show]

type editor_transport = Runtime_protocol.editor_transport =
  | Endpoint
  | Command

type editor_semantics = Runtime_protocol.editor_semantics =
  | Http_provider
  | Official_client

type editor_credential_policy = Runtime_protocol.editor_credential_policy =
  | Credentials_optional
  | Credentials_forbidden
  | Credentials_file_required

type editor_protocol = Runtime_protocol.editor_protocol =
  { protocol : string
  ; transport : editor_transport
  ; semantics : editor_semantics
  ; credential_policy : editor_credential_policy
  ; requires_non_interactive : bool
  ; provider_fields : string list
  ; required_provider_fields : string list
  }

val editor_protocols : editor_protocol list
(** Backend-owned protocols that the structured runtime editor may create.
    Protocols that parse but cannot materialize as a production runtime are
    deliberately absent. *)

val reserved_provider_ids : string list
(** Names no provider may take. A provider's bindings are a top-level table
    named after its id, so these are the top-level tables another reader
    owns, plus the obsolete ones the loader refuses. Editors read this list
    from the server instead of keeping a copy. *)

val parse_toml : Otoml.t -> (Runtime_schema.config, parse_error list) result
(** Interpret a parsed document without parsing source again. A non-table root
    is refused. Runtime semantic validation and environment-dependent home
    expansion are the same as {!parse_string}. *)

val parse_string : string -> (Runtime_schema.config, parse_error list) result
(** Parse a TOML string into a Runtime config.
    Returns [Ok config] on success, [Error errors] with all
    parse errors found. *)

type memory_recall_declaration =
  { switch : bool  (** [\[typesafeai\] memory_recall]; [false] when the key is absent. *)
  ; scope : Runtime_schema.memory_recall_scope option
        (** What [memory_recall_scope] and [memory_recall_keepers] name, whether the
            switch is on or off. [None] when neither key is there. *)
  }

val memory_recall_declaration_of_string
  :  string
  -> (memory_recall_declaration, parse_error list) result
(** What the three memory recall keys of [\[typesafeai\]] declare, read the
    way {!parse_string} reads them and refused the same ways. The switch and
    the scope stay apart: {!Runtime_schema.memory_recall} has no scope for a
    switch that is off, so a list a file keeps while recall is switched off
    by hand is visible here and nowhere else. It reads only these three
    keys; a file that {!parse_string} refuses for another reason can still
    answer. *)

val parse_file : string -> (Runtime_schema.config, parse_error list) result
(** Parse a TOML file into a Runtime config. *)

val ignored_legacy_keys : string -> string list
(** Dotted paths of the legacy keys this text still carries -- e.g.
    ["models.gpt-5.max-prompt-bytes"] -- which {!parse_string} now reads past
    without a value. Empty when the text parses without them or does not
    parse at all. A save names them in its warning rather than refusing the
    edit (#45985). *)

(** {1 Internal: protocol resolution} *)

val api_format_of_protocol : string -> (Runtime_schema.api_format, string) result
(** Map a declared TOML protocol to its API format. The parser and structured
    editor share {!Runtime_protocol}; unknown labels are rejected. *)
