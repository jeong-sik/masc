val metric_oas_params_of_schema_sec : string
val metric_oas_make_tool_bundle_sec : string
val hist_disabled : bool Lazy.t
val observe : metric:string -> start:Mtime.t -> unit
val register : unit -> unit
