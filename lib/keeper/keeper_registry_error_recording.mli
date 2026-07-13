(** Keeper error recording: log + Otel_metric_store dedup + last_error persistence. *)

(** Record [err] on keeper [name].
    - Every occurrence emits at ERROR with caller-supplied [?details].
    - Exact repeated [(keeper, err)] pairs also increment the observational
      [metric_keeper_recording_error_dedup] counter.
    - Finally writes [last_error = Some err] through
      [Keeper_registry.set_last_error_entry] (CAS retry). *)
val record :
  base_path:string -> ?details:Yojson.Safe.t -> string -> string -> unit

(** Record observability for [entry]'s lane without mutating a newer
    same-name lane's [last_error]. *)
val record_exact :
  ?details:Yojson.Safe.t -> Keeper_registry.registry_entry -> string -> unit
