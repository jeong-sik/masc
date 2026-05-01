open Base

(** Tool_usage_log -- Durable call logging for System_internal surface tools.

    Persists tool invocations to [.masc/tool_usage/YYYY-MM/DD.jsonl] via
    {!Dated_jsonl}. Only tools on the {!Tool_catalog_surfaces.System_internal}
    surface are logged, providing evidence for safe pruning decisions.

    @since 2.190.0 -- Issue #5120 *)

val init : ?cluster_name:string -> base_path:string -> unit -> unit
(** [init ?cluster_name ~base_path ()] creates the Dated_jsonl store under the
    cluster-aware [.masc/tool_usage/] root. Must be called before [install]. *)

val install : unit -> unit
(** [install ()] registers a {!Tool_dispatch} post-hook that logs
    System_internal tool calls to the JSONL store. Calls to non-System_internal
    tools are ignored. *)

val log_call : tool_name:string -> success:bool -> caller:string option -> unit
(** [log_call ~tool_name ~success ~caller] appends a single entry to the
    JSONL store. Primarily used by the post-hook; exposed for testing. *)

val source_metadata_json : masc_root:string -> Yojson.Safe.t
(** [source_metadata_json ~masc_root] reports durable [.masc/tool_usage]
    lineage, freshness, and coverage-gap state for dashboard projections. *)

val attach_source_metadata : masc_root:string -> Yojson.Safe.t -> Yojson.Safe.t
(** [attach_source_metadata ~masc_root json] overlays {!source_metadata_json}
    fields onto an existing tool usage summary object. *)

val is_system_internal : string -> bool
(** [is_system_internal name] returns true if [name] is on the
    System_internal surface. O(1) hashtable lookup. *)

val read_recent : ?n:int -> unit -> Yojson.Safe.t list
(** [read_recent ~n ()] reads the most recent [n] entries (default 10000)
    from the JSONL store. Returns [] if store is not initialized. *)

val summary : unit -> (string * int) list
(** [summary ()] returns [(tool_name, call_count)] pairs sorted by count
    descending. Reads up to 100k entries from the store. *)
