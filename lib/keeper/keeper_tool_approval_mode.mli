(** Per-keeper stance on the tool-approval gate.

    {!Keeper_tool_approval_policy} decides call by call; this module says
    whether a keeper consults it at all. [Auto] is that policy unchanged.
    [Yolo] skips it — an operator's explicit, loud choice for a keeper they
    are watching.

    What it skips, and what it does not. This stance is read in exactly one
    place: the PreToolUse hook that asks over the open chat stream. An
    external effect that goes to {!Keeper_gate} -- a write to a service this
    Keeper is attached to, a sandbox command, a durable memory write -- is
    decided there, by the workspace Gate mode and this Keeper's own override,
    and reaches its decision whatever this says. So [Yolo] is "stop asking me
    in this chat", not "let everything through": before 2026-08-27 those
    happened to be the same sentence, because writing to somebody else's Jira
    did not reach the Gate at all.

    Deliberately in-memory, like {!Keeper_tool_approval_registry}: a stance
    this permissive must not outlive the process that was told to take it. A
    restart returns every keeper to [Auto], and that is the point, not a
    gap. *)

type mode =
  | Auto  (** The approval policy decides, call by call. *)
  | Yolo
      (** Calls this hook would ask about run unasked. Effects the Gate
          decides are still decided there. *)

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
