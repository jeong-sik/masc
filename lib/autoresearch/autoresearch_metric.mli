(** Autoresearch_metric — Metric measurement and retry logic.

    Runs a shell command ([metric_fn]) via [Agent_sdk.Autonomy_exec]
    (argv-only execution, no shell interpreter) and parses either a
    strict metric-contract tag or the last non-empty stdout line as a
    float score. Supports retry on transient errors (timeout,
    connection).

    @since 2.80.0 *)

(** {1 Re-exports from [Agent_sdk.Metric_contract]}

    Convenience bindings kept for callers that only depend on this
    module. *)

val default_metric_name : string
val prompt_snippet : ?metric_name:string -> unit -> string

(** {1 Re-exports from [String_util]} *)

(** Substring containment check — re-exposed because
    [Autoresearch_file] consumes it directly. *)
val contains_substring : string -> string -> bool

(** {1 [metric_fn] validation} *)

(** Tokenise [metric_fn] into an [argv] list, rejecting shells
    metacharacters outside quotes, unterminated quotes, and multi-line
    input. *)
val split_metric_fn_argv : string -> (string list, string) result

(** [validate_metric_fn fn] returns [Ok fn] if tokenisation succeeds,
    otherwise [Error reason]. Does not execute the command. *)
val validate_metric_fn : string -> (string, string) result

(** {1 Execution} *)

(** [run_metric_argv ~workdir ~timeout_s argv] executes [argv] under
    [Agent_sdk.Autonomy_exec.run] and returns
    [(stdout, elapsed_ms)] on exit code 0, or an [Error] describing the
    failure (including clock unavailability, non-zero exit, timeout,
    signal). *)
val run_metric_argv
  :  workdir:string
  -> timeout_s:float
  -> string list
  -> (string * int, string) result

(** [measure_metric ~workdir ~timeout_s metric_fn] tokenises, runs, and
    parses [metric_fn]. On success returns [(score, elapsed_ms)];
    [Error] on tokenisation failure, exec failure, or unparsable output
    (neither a metric-contract tag nor a float on the last line). *)
val measure_metric
  :  workdir:string
  -> timeout_s:float
  -> string
  -> (float * int, string) result

(** [measure_metric_with_retry ~workdir ~timeout_s ?max_retries metric_fn]
    retries on transient errors (messages containing ["timeout"],
    ["timed_out"], or ["connection"]) with a 1-second sleep between
    attempts. [max_retries] defaults to [2] (up to 3 total attempts).
    Non-transient errors return immediately. *)
val measure_metric_with_retry
  :  workdir:string
  -> timeout_s:float
  -> ?max_retries:int
  -> string
  -> (float * int, string) result
