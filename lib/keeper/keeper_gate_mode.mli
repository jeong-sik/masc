(** Persistent operating mode for the Keeper external-effect Gate.

    Modes are independent choices with no ordering or promotion. *)

type t =
  | Manual
  | Auto_judge
  | Always_allow

type change =
  { previous : t option
  ; current : t
  ; actor : string
  ; changed_at : string
  ; replaced_read_error : string option
  }

val default : t
val to_string : t -> string
val of_string : string -> t option
val parse_json : Yojson.Safe.t -> (t, string) result
val path : base_path:string -> string

(** A missing state file selects {!default}. An existing unreadable or invalid
    file is an explicit error; callers must not silently coerce it. *)
val read : base_path:string -> (t, string) result

(** Dashboard projection. Invalid state exposes the read error and an explicit
    manual effective mode, so the Gate can defer to a human without hiding the
    configuration failure. *)
val status_json : base_path:string -> Yojson.Safe.t

val set :
  Workspace.config -> actor:string -> t -> (change, string) result

val change_json : change -> Yojson.Safe.t
