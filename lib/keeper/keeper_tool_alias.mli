(** Keeper_tool_alias — bidirectional map between LLM-facing tool names
    (Anthropic Code built-ins like [Bash], [Read]) and the internal
    keeper surface names ([keeper_bash], [keeper_fs_read], ...).

    The internal name remains the SSOT for metrics, decisions.jsonl,
    audit logs and dashboards. Aliases live alongside, not instead of,
    the internal names. *)

(** [to_internal public_name] returns the internal [keeper_*] name when
    [public_name] is a known alias. Returns [None] otherwise.

    Examples: [to_internal "Bash" = Some "keeper_bash"],
    [to_internal "Skill" = None] (no cognate). *)
val to_internal : string -> string option

(** [to_public internal_name] returns the LLM-facing alias for an
    internal [keeper_*] tool. Falls back to [internal_name] verbatim
    when the tool has no Anthropic Code cognate (board/task/etc.). *)
val to_public : string -> string

(** [canonicalize_observed names] maps every recognized public alias
    to its internal name and leaves all other names untouched. Used
    by the disclosure check to treat [Bash] as [keeper_bash] when
    counting unexpected tools. *)
val canonicalize_observed : string list -> string list

(** [hallucinated_builtins] lists the public names from the Anthropic
    Code surface that have **no** cognate in the keeper surface
    (e.g. [Skill], [Agent], [WebSearch]). These should be flagged with
    a teaching message rather than nuking the turn. *)
val hallucinated_builtins : string list

(** [is_hallucinated_builtin name] is [true] iff [name] appears in
    [hallucinated_builtins]. *)
val is_hallucinated_builtin : string -> bool

(** [all_aliases ()] returns the full alias table as
    [(public, internal)] pairs. Stable order; suitable for tests and
    documentation generation. *)
val all_aliases : unit -> (string * string) list

(** {1 OAS dual registration (Phase A.2)} *)

(** [oas_dual_register_aliases ()] is the subset of [all_aliases ()]
    that is currently safe to register with OAS as additional [Tool.t]
    entries sharing the keeper handler.

    Membership requires (a) a known input-shape translation back to the
    internal tool's schema and (b) a tailored public input_schema so
    the LLM sees the Anthropic-Code shape it expects.

    Phase A.2: [Bash], [Read]. These two account for ~80% of the
    hallucinated-builtin tool calls measured in #8778.

    Excluded (deferred to Phase A.4): [Edit] (semantic mismatch:
    Anthropic Edit does string-replace, keeper_fs_edit only overwrites);
    [Write] (covered when [Edit] is); [Grep] (needs op=rg input
    synthesis).

    Excluded aliases remain in [all_aliases ()] / [to_internal] so the
    disclosure-check canonicalization (Phase A.3) keeps treating
    [Edit]/[Write]/[Grep] as known names — turns are no longer nuked
    even though OAS still rejects the call. *)
val oas_dual_register_aliases : unit -> (string * string) list

(** [public_input_schema public_name] returns the LLM-facing JSON schema
    for an aliased tool. [None] means there is no tailored schema yet
    — callers should fall back to the internal tool's schema (which is
    not ideal because the LLM expects the Anthropic-Code field names). *)
val public_input_schema : string -> Yojson.Safe.t option

(** [translate_input ~public input] reshapes an LLM call payload from
    the public schema (Anthropic Code field names) to the internal
    keeper tool's expected payload.

    For unknown public names this is the identity. Defined for every
    name in [oas_dual_register_aliases ()].

    Examples:
    - [translate_input ~public:"Bash" {| {"command":"ls","timeout":30} |}]
      → [{| {"cmd":"ls","timeout_sec":30} |}]
    - [translate_input ~public:"Read" {| {"file_path":"x"} |}]
      → [{| {"path":"x"} |}] *)
val translate_input : public:string -> Yojson.Safe.t -> Yojson.Safe.t

(** [expand_universe internal_names] returns [internal_names] with the
    public-name aliases of every member of [oas_dual_register_aliases ()]
    appended (deduplicated, original order preserved).

    Callers building AllowList / universe / allowed_exec sets in
    [keeper_agent_run.ml] must apply this so the public alias names are
    not pruned before reaching the LLM-facing tool list. *)
val expand_universe : string list -> string list
