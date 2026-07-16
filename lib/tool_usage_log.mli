
(** Tool_usage_log -- Durable call logging for non-public registered tools.

    Persists tool invocations to [.masc/tool_usage/YYYY-MM/DD.jsonl] via
    {!Dated_jsonl}. External discovery membership is not reused as Keeper
    visibility or authorization policy.

    @since 2.190.0 -- Issue #5120 *)

val init : ?cluster_name:string -> base_path:string -> unit -> unit
(** [init ?cluster_name ~base_path ()] creates the Dated_jsonl store under the
    cluster-aware [.masc/tool_usage/] root. Must be called before [install].
    [MASC_TOOL_USAGE_LOG_RETENTION_DAYS] controls opportunistic retention;
    default is 30 days, and values <= 0 disable pruning. *)

val install : on_io_failure:(site:string -> exn -> unit) -> unit
(** [install ~on_io_failure] registers a {!Tool_dispatch} observer that logs
    non-public registered tool calls to the JSONL store. Public tools are
    already covered by their external call telemetry. [on_io_failure ~site exn]
    is invoked when a JSONL append
    raises; the installer supplies keeper FD/disk pressure handling so this
    module does not reference the keeper subsystem (Tool->Keeper dependency
    direction). *)

val log_call :
  on_io_failure:(site:string -> exn -> unit) ->
  tool_name:string ->
  disposition:('completed, 'deferred, 'failed) Tool_result.disposition ->
  caller:string option ->
  unit
(** [log_call ~on_io_failure ~tool_name ~disposition ~caller] appends a single
    entry to the JSONL store. Primarily used by the dispatch observer; exposed
    for testing. [on_io_failure] receives the append exception (if any). *)

val source_metadata_json : masc_root:string -> Yojson.Safe.t
(** [source_metadata_json ~masc_root] reports durable [.masc/tool_usage]
    lineage, freshness, and coverage-gap state for dashboard projections. *)

val attach_source_metadata : masc_root:string -> Yojson.Safe.t -> Yojson.Safe.t
(** [attach_source_metadata ~masc_root json] overlays {!source_metadata_json}
    fields onto an existing tool usage summary object. *)

val read_recent : ?n:int -> unit -> Yojson.Safe.t list
(** [read_recent ~n ()] reads the most recent [n] entries (default 10000)
    from the JSONL store. Returns [] if store is not initialized. *)

val summary : unit -> (string * int) list
(** [summary ()] returns [(tool_name, call_count)] pairs sorted by count
    descending. Reads up to 100k entries from the store. *)
