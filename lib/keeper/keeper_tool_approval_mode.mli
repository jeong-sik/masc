(** Per-keeper stance on the tool-approval gate.

    {!Keeper_tool_approval_policy} decides call by call; this module says
    whether a keeper consults it at all. [Auto] is that policy unchanged.
    [Yolo] runs every call unasked — an operator's explicit, loud choice for
    a keeper they are watching.

    Deliberately in-memory, like {!Keeper_tool_approval_registry}: a stance
    this permissive must not outlive the process that was told to take it. A
    restart returns every keeper to [Auto], and that is the point, not a
    gap. *)

type mode =
  | Auto  (** The approval policy decides, call by call. *)
  | Yolo  (** Every call runs unasked. *)

val mode_to_string : mode -> string
val mode_of_string : string -> mode option

type t

val create : unit -> t

val shared : unit -> t
(** The instance the running server uses — the gate that consults and the
    HTTP handler that sets have to reach the same stances. [create] stays
    for tests. *)

val resolve : t -> keeper_name:string -> mode
(** A keeper nobody has spoken about is [Auto]. *)

val set : t -> keeper_name:string -> mode -> unit
(** Setting [Auto] removes the override rather than storing a synonym for
    the default, so {!overrides} lists exactly the keepers an operator has
    moved off it. *)

val overrides : t -> (string * mode) list
(** Every keeper currently moved off [Auto], in the order they were set. *)
