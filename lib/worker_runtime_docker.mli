(** Worker_runtime_docker — Docker-backed worker runtime.

    Spawns each worker run as a short-lived Docker container with
    the [masc-worker-run] helper binary inside.  Mounts the host
    base path read-only, rewrites loopback URLs to
    [host.docker.internal] so the helper can reach the host MCP /
    llama runtime, and persists stderr to an artifact path on
    abnormal exit.

    Three external entries:
    - {!preflight_batch}: per-batch reachability + image / auth
      check (called once before spawning).
    - {!rewrite_spec_for_container}: in-memory spec mutation
      (model label + URL rewriting).
    - {!run_worker_spec}: actual single-worker run.

    Internal: tail truncation, exit-code mapping,
    container-name / artifact-path builders, env-allowlist /
    docker-arg builders, auth requirement check, container counter
    Atomic — all kept private.  The .mli pins the runtime contract,
    not the docker plumbing. *)

(** {1 Preflight} *)

type preflight_subject = {
  worker_name : string;
  model_label : string;
}
(** Minimal per-worker descriptor for {!preflight_batch}.
    Concrete record because callers (notably
    {!Worker_container_runners.preflight_spawn_batch}) construct
    it field-by-field. *)

val preflight_batch :
  ?clock_opt:_ -> preflight_subject list -> (unit, string) result
(** [preflight_batch ?clock_opt subjects] runs the per-batch
    reachability check.  Returns:

    - [Error _] when the docker image is unconfigured / unreachable,
      [docker info] fails, or any subject's auth requirements are
      not satisfied.
    - [Ok ()] when every subject can be safely spawned.

    Pinned at the contract seam: this is a {b batch} preflight,
    not per-worker.  Caller is expected to call once before
    spawning all workers in the batch — Errors short-circuit the
    whole batch. *)

(** {1 Spec rewriting} *)

val rewrite_model_label_for_container :
  string -> string
(** [rewrite_model_label_for_container label] rewrites the model
    label for in-container use.  [custom:*] labels pass through
    unchanged; loopback URLs in the label become
    [host.docker.internal] equivalents. *)

val rewrite_spec_for_container :
  Worker_execution_spec.t -> Worker_execution_spec.t
(** [rewrite_spec_for_container spec] returns [spec] with
    [model_label] rewritten via {!rewrite_model_label_for_container}.
    Pure — no side effects. *)

(** {1 Run} *)

val run_worker_spec :
  ?clock_opt:_ ->
  Worker_execution_spec.t ->
  (Worker_container_types.run_result, string) result
(** [run_worker_spec ?clock_opt spec] spawns a Docker container
    that runs the [masc-worker-run] helper with the encoded spec.

    Container lifecycle:
    + Generate unique container name (counter + worker id).
    + Allocate stderr artifact path.
    + Build docker argv (image + mount + env + helper invocation).
    + Spawn via {!run_process_with_timeout}; capture stdout / stderr.
    + Persist stderr to the artifact path on non-zero exit.
    + Best-effort container removal on any exit.

    Returns the parsed [run_result] on success, or an error message
    on docker / helper / parse failure. *)

(** {1 Process spawn (test-visible)} *)

type process_result = {
  exit_code : int;
  stdout : string;
  stderr : string;
}
(** Synchronous subprocess result.  Exposed because
    {!run_process_with_timeout} is test-visible. *)

val run_process_with_timeout :
  ?stdin_content:string ->
  clock_opt:_ ->
  timeout_sec:int ->
  prog:_ ->
  argv:string list ->
  env:string array ->
  unit ->
  process_result
(** [run_process_with_timeout ?stdin_content ~clock_opt ~timeout_sec
      ~prog ~argv ~env ()] runs [argv] via
    {!Masc_exec.Exec_gate.run_argv_with_status_split}.

    Pinned audit metadata: actor =
    [system/worker_runtime_docker], summary =
    [worker runtime docker subprocess].  These strings appear in
    the exec audit log and operator dashboards — drift breaks
    operator filtering.

    Exit-code mapping (signal-aware): [WEXITED code -> code],
    [WSIGNALED code -> 128 + code],
    [WSTOPPED code -> 256 + code]. *)
