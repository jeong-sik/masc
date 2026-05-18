(** Cascade_codex_omission_dedup — per-agent + per-fingerprint dedup
    for codex_cli's runtime MCP tool omissions (issue #10097).

    Extracted from [Cascade_transport] for godfile decomposition
    (Doc #5 step 9: "Cascade transport split").  Behavior unchanged;
    [Cascade_transport] re-exports every entry below so external
    callers keep their existing module path.

    Why dedup at all: codex_cli can only expose keeper-bound runtime
    MCP tools when the keeper has a raw bearer token that OAS can
    route through [bearer_token_env_var].  Missing-token omissions are
    a structural lane/auth setup issue, not a per-call incident.  So:

    - [WARN] emits only when an agent first sees an omitted-tool
      fingerprint, or when that agent's omitted tool set changes.
    - [Prometheus] per-tool counter increments on every omission so
      dashboards retain the frequency signal.

    Fingerprint = sorted, comma-joined tool list.  [Stdlib.Mutex]
    guards concurrent access from heartbeat/turn fibers across
    domains. *)

val codex_cli_omission_fingerprint : string list -> string
(** Sorted, comma-joined fingerprint of an omitted tool list.  Two
    different orderings of the same set produce the same fingerprint. *)

val codex_cli_omission_fingerprint_seen : string -> bool
(** [true] when this exact fingerprint has been seen before under the
    fallback [<no_agent>] key.  Equivalent to
    [not (codex_omission_should_log ~agent_name:"<no_agent>" ~tool_fingerprint:fingerprint)]. *)

val record_codex_cli_omission_for_agent
  :  agent_name:string option
  -> tools:string list
  -> unit
(** Records a codex_cli omission for a specific agent.  Always
    increments the Prometheus counter; emits [WARN] only on the first
    distinct fingerprint per agent (or when that agent's omitted set
    changes).  Empty [tools] is a no-op. *)

val record_codex_cli_omission : tools:string list -> unit
(** Convenience wrapper for [record_codex_cli_omission_for_agent
    ~agent_name:None].  Used by the legacy call site that does not
    track agent identity. *)

val reset_codex_cli_omission_dedup_for_tests : unit -> unit
(** Test-only: clears the per-agent dedup table so each Alcotest case
    starts from a known empty state.  Production code must not call
    this. *)
