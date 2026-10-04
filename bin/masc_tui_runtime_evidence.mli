type t
(** Operator history joins only by an observed runtime ID. Configuration
    specifications are a separate current reading, never inferred from history. *)
val decode : Yojson.Safe.t -> (t, string) result
val lines : t -> runtime_id:string -> (string * string) list
(** Label/value rows for the detail view, including explicit absent evidence. *)
