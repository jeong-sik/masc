(** Codex CLI tool-omission warning dedup.

    Suppresses repeated WARN log entries when the codex CLI omits the
    same set of keeper-bound runtime MCP tools across consecutive
    calls, while still incrementing the Prometheus counter
    [masc_provider_mcp_tool_omission_total] for every omission.

    Thread-safe via [Stdlib.Mutex] — no Eio dependency, callable
    during module initialisation. *)

(** [codex_cli_omission_fingerprint tools] returns the canonical
    sorted-comma fingerprint used as the dedup key. *)
val codex_cli_omission_fingerprint : string list -> string

(** [codex_cli_omission_fingerprint_seen fingerprint] returns [true]
    when the [<no_agent>] dedup bucket already contains [fingerprint].
    Side-effect-free with respect to other agent buckets. *)
val codex_cli_omission_fingerprint_seen : string -> bool

(** [reset_codex_cli_omission_dedup_for_tests ()] clears the dedup
    state. Test-only — invoked at the start of each unit test for
    reproducibility. *)
val reset_codex_cli_omission_dedup_for_tests : unit -> unit

(** [record_codex_cli_omission_for_agent ~agent_name ~tools]
    increments the Prometheus omission counter once per [tool] in
    [tools] and emits a single WARN per (agent, fingerprint) pair.
    When [agent_name] is [None] the key falls back to [<no_agent>]. *)
val record_codex_cli_omission_for_agent
  :  agent_name:string option
  -> tools:string list
  -> unit

(** [record_codex_cli_omission ~tools] is
    [record_codex_cli_omission_for_agent ~agent_name:None ~tools]. *)
val record_codex_cli_omission : tools:string list -> unit
