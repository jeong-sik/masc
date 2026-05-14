(** Local filesystem artifact store for CDAL proof bundles.

    Part of the Contract-Driven Agent Loop (CDAL) PoC-1.
    Stores proof manifests, contract snapshots, tool traces,
    and evidence artifacts under [{root}/proofs/{run_id}/].

    @stability Evolving
    @since 0.93.1 *)

type config = { root : string (** Default: [~/.oas] *) }

type resolved_ref =
  { run_id : string
  ; subpath : string
  ; path : string
  }

val default_config : config

(** Create directory structure for a new run. *)
val init_run : config -> run_id:string -> unit

(** Write the 15-field proof manifest. *)
val write_manifest : config -> run_id:string -> Cdal_proof.t -> unit

(** Write the frozen contract snapshot. *)
val write_contract : config -> run_id:string -> Risk_contract.t -> unit

(** Append a single tool trace entry (JSONL). *)
val append_tool_trace
  :  config
  -> run_id:string
  -> trace_id:string
  -> Yojson.Safe.t
  -> unit

(** Write a raw evidence artifact. *)
val write_evidence : config -> run_id:string -> ref_id:string -> Yojson.Safe.t -> unit

(** Construct a [proof-store://] artifact reference. *)
val make_ref : run_id:string -> subpath:string -> Cdal_proof.artifact_ref

(** Path to manifest.json for a run. *)
val manifest_path : config -> run_id:string -> string

(** Resolve a [proof-store://] artifact reference into its run-scoped path. *)
val resolve_ref : config -> Cdal_proof.artifact_ref -> (resolved_ref, string) result

(** Read a JSON artifact referenced by [proof-store://]. *)
val read_json : config -> Cdal_proof.artifact_ref -> (Yojson.Safe.t, string) result

(** Read a JSONL artifact referenced by [proof-store://]. *)
val read_jsonl : config -> Cdal_proof.artifact_ref -> (Yojson.Safe.t list, string) result

(** Load and decode a stored proof manifest by [run_id]. *)
val load_manifest
  :  config
  -> run_id:string
  -> (Cdal_proof.t * Yojson.Safe.t, string) result

(** Load and decode a stored contract snapshot by [run_id]. *)
val load_contract
  :  config
  -> run_id:string
  -> (Risk_contract.t * Yojson.Safe.t, string) result

(** List known proof-store run IDs. *)
val list_runs : config -> (string list, string) result

(** {1 Cross-run window support}

    @since cross-run-temporal *)

(** Run metadata for ordering and filtering. *)
type run_info =
  { run_id : string
  ; ended_at : float
  ; schema_version : int
  ; scope : string option
  }

(** Resource bounds for cross-run queries. *)
type window_bounds =
  { max_runs : int
  ; max_bytes : int
  }

val default_window_bounds : window_bounds

(** List runs with metadata, ordered by [ended_at] ascending,
    tie-broken by [run_id].
    Corrupted manifests are excluded from the result and reported
    in the second element of the tuple.
    Returns [Error] when the number of matching runs exceeds
    [bounds.max_runs].
    @since cross-run-temporal *)
val list_runs_ordered
  :  config
  -> ?scope:string
  -> ?bounds:window_bounds
  -> unit
  -> (run_info list * string list, string) result

(** Load manifests for a window of runs.
    Readable runs are returned; unreadable runs are reported
    in the second element of the tuple.
    Returns [Error] when [run_ids] length exceeds [bounds.max_runs]
    or when accumulated manifest bytes exceed [bounds.max_bytes].
    @since cross-run-temporal *)
val load_window
  :  config
  -> run_ids:string list
  -> ?bounds:window_bounds
  -> unit
  -> ((Cdal_proof.t * Yojson.Safe.t) list * string list, string) result
