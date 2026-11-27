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
  ; supports_image_input : bool
  ; supports_image_output : bool
  }

type resolved =
  { default_runtime_id : string option
  ; default_model : string option
  ; default_max_context : int option
  ; runtimes : runtime_entry list
  ; media : Runtime_schema.media_overrides
  ; config_path : string option
  }

val build : generated_at_iso:string -> resolved -> Yojson.Safe.t
(** Pure JSON encoder over the resolved structure. *)

val current : generated_at_iso:string -> unit -> Yojson.Safe.t
(** [build] applied to {!resolved_of_runtime}. *)

val current_prepared : unit -> Server_cached_read_http.prepared_http
(** Pre-encoded HTTP payload + ETag for {!current}, memoized while the
    published runtime snapshot stays physically unchanged. *)
