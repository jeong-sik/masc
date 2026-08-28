(** Read-only projection of the durable async request inventory, current-process
    worker ownership, and the last startup recovery report. *)

val project : base_path:string -> Yojson.Safe.t
