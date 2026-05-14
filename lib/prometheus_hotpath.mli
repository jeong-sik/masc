(** OAS dispatch hot-path metric helpers. *)

(** Histogram: elapsed seconds per [Tool_bridge.params_of_json_schema]
    call.  Observation gated by [MASC_DISABLE_HOTPATH_HIST]. *)
val metric_oas_params_of_schema_sec : string

(** Histogram: elapsed seconds per [Keeper_tools_oas.make_tool_bundle]
    call.  Fires once per keeper turn. *)
val metric_oas_make_tool_bundle_sec : string

(** Phase B baseline opt-out, read once at module load. *)
val hist_disabled : bool Lazy.t

(** Observe a hot-path histogram from a pre-call [Mtime] timestamp.
    Internal exceptions are swallowed; cancellation is re-raised. *)
val observe : metric:string -> start:Mtime.t -> unit

val register : unit -> unit
