(** Per-caller subprocess execution timeout SSOT (#10426).

    See {!Env_config_oas_bridge} for the original precedent (#10094). *)

(** Caller variants — one per code site that previously held a
    hardcoded [~timeout_sec:N.N] literal.  Add a new variant when a
    new exec-timeout site emerges; otherwise use [Unknown of string]. *)
type caller =
  | Shell
  | Fs
  | Preflight
  | Repo_readiness
  | Sandbox
  | Pr_review
  | Pr_review_post
      (** [gh pr review --body --event] mutation (post a review with
          body).  Default 30.0s — server-side processing of the
          review state machine + notification fanout is materially
          slower than read ops; the [Pr_review] 15s read budget is
          too tight here. *)
  | Dispatch
  | Memory_audit
  | Alerting
  | Gh_shared
  | Status_detail
  | Turn_sandbox
  | Turn_up
  | Git_meta
      (** Local git metadata commands (e.g. [git remote get-url],
          [git rev-parse]).  Default 10.0s — local disk operations
          that should complete in <1s; however, some sites invoke
          [git remote] over network-origin remotes where DNS and TLS
          add latency, so 10s provides a reasonable ceiling. *)
  | Autoresearch_git_meta
      (** Autoresearch local git metadata commands. Default 10.0s,
          preserving the previous inline budget for rev-parse/tag
          metadata reads inside the experiment loop. *)
  | Autoresearch_git_mutation
      (** Autoresearch local git mutation commands. Default 30.0s,
          preserving the previous inline budget for add/commit/reset/
          worktree cleanup inside managed experiment loops. *)
  | Shell_probe
      (** PATH availability probes (e.g. [command -v <name>]).
          Default 2.0s — pure OS lookup; longer timeouts mask
          shell-startup misconfiguration rather than helping. *)
  | Graphql
      (** [Graphql_client.{request,query,mutate}] HTTP calls.
          Default 10.0s — preserves the 8-10s literals previously
          held by relation_materializer, dashboard_agent_relations,
          dashboard_execution_helpers, and autoresearch_knowledge. *)
  | Http
      (** Outbound JSON POST probes via [http_post_json_text_with_status]
          (e.g. tool_local_runtime_verify).  Default 15.0s, matching
          the previous inline budget. *)
  | Startup
      (** Server bootstrap and room takeover read paths.
          Default 30.0s — preserves the [server_bootstrap_loops]
          docker preflight budget.  Note: the
          [server_startup_takeover] [ps] probe was previously 1s —
          it now uses [Shell_probe] (2s) instead of [Startup] so a
          single env override does not move two unrelated budgets. *)
  | Auto_responder
      (** Auto-responder CLI spawn with stdin prompt.  Default 120.0s
          — preserves the previous inline budget; under-budgeting
          here would silently cut off legitimate model replies. *)
  | Build_identity
      (** Build identity git probe.  Default 5.0s. *)
  | Voice
      (** Voice bridge local playback subprocess.  Default 60.0s —
          preserves the previous inline budget. *)
  | Coord_identity
      (** Coord tty identity probe.  Default 5.0s. *)
  | Dashboard
      (** Dashboard safe_autonomy short heartbeat probe.
          Default 3.0s — matches the previous inline budget. *)
  | Http_routes
      (** Workspace API git command invoked via the HTTP routes layer.
          Default 15.0s. *)
  | Test
      (** Test fixtures driving the exec runtime.
          Default 30.0s — matches the [test_slow_command_promotes]
          ceiling; faster fixtures may override per-caller. *)
  | Unknown of string

(** [caller_key c] is the lowercase identifier embedded in env var
    names and Prometheus labels. *)
val caller_key : caller -> string

(** [known_callers ()] exposes the typed-default table for pinning
    in tests. *)
val known_callers : unit -> caller list

(** [known_default_sec c] is the hardcoded default for [c],
    or [None] for [Unknown _].  Tests use this to verify the
    per-caller defaults haven't drifted. *)
val known_default_sec : caller -> float option

(** [per_caller_env_var ~caller] is [MASC_EXEC_TIMEOUT_<CALLER>_SEC]. *)
val per_caller_env_var : caller:caller -> string

(** [global_env_var] is [MASC_EXEC_TIMEOUT_DEFAULT_SEC] — only
    consulted for [Unknown] callers. *)
val global_env_var : string

(** [global_default_sec] is the final fallback (30.0s). *)
val global_default_sec : float

(** [timeout_sec ~caller ()] resolves the subprocess timeout for
    [caller].  See module doc for lookup order. *)
val timeout_sec : caller:caller -> unit -> float

(** [timeout_sec_int ~caller ()] is [timeout_sec] rounded UP to the
    nearest second.  Use at call sites whose downstream helper signs
    [~timeout_sec:int] — e.g.
    {!Tool_local_runtime_http.http_post_json_text_with_status} and
    {!Worker_runtime_docker.run_process_with_timeout}.  Returns
    [1] for non-positive or NaN budgets so the call always issues
    a finite-bound subprocess. *)
val timeout_sec_int : caller:caller -> unit -> int
