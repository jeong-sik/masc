(** Dashboard [/api/v1/dashboard/runtime-defaults] endpoint JSON builder.

    Serves the structured, already-resolved runtime defaults and model routing
    (runtime.toml SSOT, populated by [Runtime.init_default]). Unknown /
    uninitialized state surfaces as [null]/[[]] — no fabricated defaults. *)

type runtime_entry =
  { id : string
  ; provider : string
  ; model : string
  ; max_context : int
  ; is_default : bool
  }

type memory_os_consolidation_resolution =
  | Consolidation_resolved of string
  | Consolidation_inherited of string
  | Consolidation_error of string

type resolved =
  { default_runtime_id : string option
  ; default_model : string option
  ; default_max_context : int option
  ; runtimes : runtime_entry list
  ; memory_os_consolidation_runtime_id : string option
  ; memory_os_consolidation : memory_os_consolidation_resolution
  ; structured_judge_runtime_id : string option
  ; cross_verifier_runtime_id : string option
  ; media_failover : string list
  ; config_path : string option
  }

val build : generated_at_iso:string -> resolved -> Yojson.Safe.t
(** Pure JSON encoder over the resolved structure. *)

val resolved_of_snapshot : Runtime.dashboard_runtime_defaults_snapshot -> resolved
(** Project one typed Runtime snapshot into the dashboard wire structure without
    rereading mutable runtime state. *)

val resolved_of_runtime : unit -> resolved
(** Capture one typed Runtime snapshot and project it. *)

val current : generated_at_iso:string -> unit -> Yojson.Safe.t
(** [build] applied to {!resolved_of_runtime}. *)
