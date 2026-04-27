(** Background task lifecycle management for keeper shell.

    Extracted from keeper_exec_shell.ml — poll and kill operations
    for background bash tasks spawned by handle_keeper_bash. *)

(** Encode a [Unix.process_status option] (None = still running) as
    JSON via [Keeper_alerting_path.process_status_to_json]. *)
val status_to_json_opt : Unix.process_status option -> Yojson.Safe.t

(** Map the [signal] arg ("TERM", "KILL", numeric, etc.) to a Unix
    signal int. Default [Sys.sigterm] for missing/unknown values. *)
val signal_of_name_or_num : Yojson.Safe.t -> int

(** [masc_keeper_bash_output] handler: poll a background bash task
    started by [handle_keeper_bash], returning new stdout/stderr
    bytes since [since_stdout]/[since_stderr], the closed flag, and
    optional exec-semantic hint. Returns a JSON-encoded string. *)
val handle_keeper_bash_output :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string

(** [masc_keeper_bash_kill] handler: terminate a background bash task
    with the given signal and grace seconds (clamped to 0..30). *)
val handle_keeper_bash_kill :
  config:Coord.config ->
  meta:Keeper_types.keeper_meta ->
  args:Yojson.Safe.t ->
  string
