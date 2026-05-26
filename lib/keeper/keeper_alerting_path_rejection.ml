(** Keeper_alerting_path_rejection — typed path-rejection variant and
    error message/telemetry helpers extracted from [Keeper_alerting_path]
    (527 LoC).  Path normalization, resolution, and sandbox helpers
    remain in the parent.
    @since Keeper 500-line decomposition *)

(** Keeper_alerting path safety and tool output helpers. *)

(** Phase 1 typed path-rejection variant.
    Replaces the prior string-only error path so that telemetry
    (Prometheus labels) and user-facing messages are derived from
    a single SSOT constructor instead of scattered [Printf.sprintf]
    sites. See CLAUDE.md §workaround-rejection-bar #2. *)
type keeper_path_rejection =
  | Path_required
  | Absolute_path_rejected of { raw : string }
  | Outside_project_root of { raw : string }
  | Allowed_paths_normalized_empty of { count : int }
  | Outside_sandbox of { raw : string }
  | Not_found_relative of { raw : string }
  | Ambiguous_relative_read_path of { raw : string; candidate_count : int }

(** LLM-facing opaque message.  Preserves legacy string prefixes so
    downstream string classifiers ([Keeper_failure_circuit_breaker.
    classify_error]) keep recognising the error class. *)
let rejection_to_user_message = function
  | Path_required -> "path_required"
  | Absolute_path_rejected { raw } ->
    Printf.sprintf
      "path_outside_project_root: %s (absolute paths are not allowed; use \
       sandbox-relative paths like 'repos/X/lib/foo.ml')"
      raw
  | Outside_project_root { raw } ->
    Printf.sprintf "path_outside_project_root: %s" raw
  | Allowed_paths_normalized_empty { count } ->
    Printf.sprintf
      "allowed_paths_normalized_empty: %d entries provided, none resolved to a \
       valid path"
      count
  | Outside_sandbox { raw } ->
    Printf.sprintf "path_outside_sandbox: %s" raw
  | Not_found_relative { raw } ->
    Printf.sprintf
      "path_not_found_under_allowed_roots: %s (this path is outside your \
       allowed playground; check your_playground for available files)"
      raw
  | Ambiguous_relative_read_path { raw; candidate_count } ->
    Printf.sprintf
      "ambiguous_relative_read_path: %s (%d candidate matches; disambiguate the \
       relative segment)"
      raw
      candidate_count
;;

(** Operator-facing telemetry — single call site for all path-rejection
    counters.  The [kind] label is derived from the constructor name,
    eliminating hard-coded label strings scattered across the resolver. *)
let rejection_to_telemetry (r : keeper_path_rejection) : unit =
  let kind =
    match r with
    | Path_required -> "path_required"
    | Absolute_path_rejected _ -> "absolute_path_rejected"
    | Outside_project_root _ -> "outside_project_root"
    | Allowed_paths_normalized_empty _ -> "allowed_paths_normalized_empty"
    | Outside_sandbox _ -> "out_of_roots"
    | Not_found_relative _ -> "not_found_relative"
    | Ambiguous_relative_read_path _ -> "ambiguous_relative_read_path"
  in
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_path_rejection
    ~labels:[ "kind", kind ]
    ()
;;

