(** Autoresearch_storage — filesystem persistence for the
    autoresearch loop.

    Owns the layout under [<base_path>/.masc/autoresearch/<loop_id>/]
    (cycle results, state JSON, execution link files). Path builders
    ([results_dir] / [results_file] / [state_file] / [loop_link_file]
    / [session_link_file]) are exposed because {!Autoresearch} re-
    exports them as part of its public surface; JSON IO helpers
    ([load_json_file_result] / [decode_json_file_result]) remain
    hidden — callers consume the typed read/write functions only.

    The [_result]-suffixed loaders return
    [(T, string) result option] so callers can distinguish
    [None] (no file on disk), [Some (Ok t)] (parsed), and
    [Some (Error msg)] (legacy/invalid format with a diagnostic
    message). The plain loaders log the error and degrade to
    [option]. *)

(** {1 Filesystem helper} *)

val ensure_dir : string -> unit
(** [mkdir -p] equivalent. Idempotent; no-op if [path] already
    exists. *)

(** {1 Path builders (per [loop_id] under [base_path])} *)

val results_dir : base_path:string -> string -> string
(** [<base_path>/.masc/autoresearch/<loop_id>/]. Parent directory for
    every other layout artifact below. *)

val results_file : base_path:string -> string -> string
(** [<results_dir>/results.jsonl]. *)

val state_file : base_path:string -> string -> string
(** [<results_dir>/state.json]. *)

val loop_link_file : base_path:string -> string -> string
(** [<results_dir>/swarm.json] keyed by [loop_id]. *)

val session_link_file : base_path:string -> string -> string
(** Per-session execution link mirror; keyed by [session_id]. *)

(** {1 Worktree path SSOT} *)

val managed_worktree_dir : base_path:string -> string -> string
(** [<base_path>/.masc/autoresearch/<loop_id>/worktree]. Used by
    [autoresearch_git.cleanup_managed_worktree] to locate the
    autoresearch driver's managed git worktree. *)

(** {1 Cycle results (append-only JSONL)} *)

val append_cycle :
  base_path:string -> string -> Autoresearch_types.cycle_record -> unit
(** Append a cycle record to [<loop_id>/results.jsonl]. Creates the
    directory on first call. *)

val latest_cycle_record :
  base_path:string -> string -> Autoresearch_types.cycle_record option
(** Last well-formed cycle record from [results.jsonl], or [None] if
    the file is missing/empty. Malformed lines are logged and
    skipped. *)

val load_cycle_history :
  base_path:string -> string -> Autoresearch_types.cycle_record list
(** Full cycle history (in file order). Malformed lines are logged
    and skipped. *)

(** {1 Loop state (single-file JSON)} *)

val save_state :
  base_path:string -> Autoresearch_types.loop_state -> unit

val load_state :
  base_path:string -> string -> Autoresearch_types.persisted_summary option
(** [Some summary] on success, [None] if the file is missing or fails
    to parse. The error path is logged. The decoded shape is the
    persisted summary (a wider view than [loop_state]). *)

val load_state_result :
  base_path:string ->
  string ->
  (Autoresearch_types.persisted_summary, string) result option
(** [None] = no file on disk. [Some (Ok summary)] = parsed (with
    [updated_at] back-filled from file mtime if absent). [Some (Error
    msg)] = legacy schema (missing [model_model] field) or decode
    failure. *)

val scan_persisted_loop_ids : base_path:string -> string list
(** Loop IDs whose [state.json] currently exists under
    [<base_path>/.masc/autoresearch/]. Used by callers that want to
    enumerate every persisted loop without opening each one. *)

(** {1 Execution link (per-loop and per-session)} *)

val save_execution_link :
  base_path:string -> Autoresearch_types.execution_link -> unit
(** Writes both the [loop -> link] and [session -> link] mappings. *)

val load_execution_link_by_loop :
  base_path:string -> string -> Autoresearch_types.execution_link option

val load_execution_link_by_loop_result :
  base_path:string ->
  string ->
  (Autoresearch_types.execution_link, string) result option

val load_execution_link_by_session :
  base_path:string -> string -> Autoresearch_types.execution_link option

val load_execution_link_by_session_result :
  base_path:string ->
  string ->
  (Autoresearch_types.execution_link, string) result option
