(** Keeper error recording: log + Otel_metric_store dedup + last_error persistence. *)

(** Record [err] on keeper [name].
    - First occurrence emits at ERROR (with [?details] sandbox context).
    - Repeated occurrences demote to DEBUG and bump
      [metric_keeper_recording_error_dedup] (label [error_kind]).
    - Finally writes [last_error = Some err] through
      [Keeper_registry.set_last_error_entry] (CAS retry). *)
val record :
  base_path:string -> ?details:Yojson.Safe.t -> string -> string -> unit

(** Record observability for [entry]'s lane without mutating a newer
    same-name lane's [last_error]. *)
val record_exact :
  ?details:Yojson.Safe.t -> Keeper_registry.registry_entry -> string -> unit
