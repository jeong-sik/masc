(** Fixed, non-interactive page UI. Pointer coordinates come only from trusted
    browser input events; an intended target is never reported as observed. *)
val runtime : string
val begin_script : string
val begin_record_script : string
val finish_script : string

type outcome = Finished | Refused | Unknown
val outcome_to_json : outcome -> Yojson.Safe.t
