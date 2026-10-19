(** Read-only projection of the durable async request inventory, current-process
    worker ownership, and the last startup recovery report. *)

val project : base_path:string -> Yojson.Safe.t

val project_request : base_path:string -> submitted_by:string -> request_id:string -> Yojson.Safe.t
(** Exact read-only lookup, including terminal physical attempts and a separate
    logical Composition observation. Does not enumerate history, recover a
    worker, create authority or turn unavailable evidence into absence.
    [submitted_by] is the original physical request owner, which may differ
    from its target Keeper. The HTTP caller still needs operator permission. *)
