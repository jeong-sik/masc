(** Which Lane: one id type for every lane the operator lists, turns on and
    off, and reads the state of (RFC every-lane-is-one-row-in-one-registry
    §2.1). Built-in lanes are compiled into the server and enumerated here.
    Package lanes are Lane Add-on declaration files. *)

(** [all_of_builtin] (derived) lists every built-in lane once: exact-output
    lanes, then Browser Lane backends, then machines, each in its own type's
    constructor order. *)
type builtin =
  | Exact of Standalone_lane.t
  | Browser of Browser_lane.Lane_name.t
  | Machine of Machine_lane.t
[@@deriving enumerate]

type t =
  | Builtin of builtin
  | Package of Declaration_file.t

val equal_builtin : builtin -> builtin -> bool

val to_wire : t -> string
(** [exact/<Standalone_lane.to_id>], [browser/<Browser_lane.Lane_name.to_wire>],
    [machine/<Machine_lane.to_wire>] or [package/<Declaration_file.to_string>]. *)

val of_wire : string -> t option
(** The id whose {!to_wire} is the argument. A string no built-in lane
    carries, a family this module does not name, or a package name
    [Declaration_file.of_name] refuses reads as [None]. *)
