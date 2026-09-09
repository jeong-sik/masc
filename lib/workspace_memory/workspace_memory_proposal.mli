type claim = { claim : string; source_ids : string list }
type conflict = { description : string; source_ids : string list }
type exclusion = { source_id : string; reason : string }
type t
type error = Invalid of string | Unavailable of string

val decode : Yojson.Safe.t -> (t, string) result
val to_json : t -> Yojson.Safe.t
val claims : t -> claim list
val conflicts : t -> conflict list
val exclusions : t -> exclusion list
val id : t -> string
val submit : base_path:string -> Yojson.Safe.t -> (string * t, error) result
val read : base_path:string -> id:string -> (t option, error) result
val list : base_path:string -> ((string * t) list, error) result
(** Missing storage is empty. Corrupt or unreadable storage is an error, never
    an empty result. Proposals remain model-proposed and do not change any
    Keeper memory. Submission validates reference structure, not truth. *)
